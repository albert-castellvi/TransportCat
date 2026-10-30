#!/usr/bin/env python3
"""Build the compact schedule pack the app bundles, from TMB's static GTFS.

S1 of ``odd/tasks/schedule-delay.md``. Python 3 standard library only.

The feed is an 8 MB zip holding 58 MB of ``stop_times``; the pack reduces it to
``index.json`` plus one small JSON file per line, so the phone never parses
GTFS:

    index.json            version, feed version/range, timezone, one entry per line
    <mode>-<code>.json    dates -> day type, directions -> patterns + starts

A day type is one distinct daily schedule of a line: two dates share a day type
when their active services produce the same sorted (start, pattern) runs. That
is the only identity a ``date -> day type`` lookup needs, and it keeps the pack
small when the feed gives every date its own ``service_id`` (as TMB does).

Line code: the second dot-separated part of ``route_id`` (``1.94.1`` -> ``94``,
``2.212.2997`` -> ``212``). Stop code: the numeric ``stop_code`` of ``stops.txt``,
which equals the second part of ``stop_id`` for every boarding stop
(``1.111`` -> ``111``, ``2.7.674433`` -> ``7``).
"""

import argparse
import collections
import csv
import datetime
import hashlib
import io
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile

FEED_URL = "https://api.tmb.cat/v1/static/datasets/gtfs.zip"
MODES = {1: "metro", 3: "bus", 7: "funicular"}
PACK_VERSION = 1
DEFAULT_TIMEZONE = "Europe/Madrid"
# The bundled pack must stay small; the app loads one file per line on demand.
SIZE_BUDGET = 15 * 1024 * 1024
REQUIRED_MEMBERS = ("routes.txt", "stops.txt", "trips.txt", "stop_times.txt")


class BuildError(Exception):
    """A failure reported as one clear line and a non-zero exit code."""


# --- GTFS reading -----------------------------------------------------------


def _rows(archive, member):
    """Yield the rows of one archive member as dicts (streamed, not a list)."""
    if member not in archive.namelist():
        raise BuildError("missing member in the GTFS archive: " + member)
    with archive.open(member) as handle:
        text = io.TextIOWrapper(handle, encoding="utf-8-sig", newline="")
        yield from csv.DictReader(text)


def _optional_rows(archive, member):
    """Yield the rows of a member that may be absent (calendar, frequencies)."""
    if member in archive.namelist():
        yield from _rows(archive, member)


def _int(value):
    """Parse an integer field, tolerating empty strings and stray spaces."""
    if value is None:
        return None
    text = value.strip()
    return int(text) if text.lstrip("-").isdigit() else None


def _date(value, label):
    """Parse a YYYYMMDD field into a date, or fail with a clear message."""
    text = (value or "").strip()
    if len(text) != 8 or not text.isdigit():
        raise BuildError("%s must be a YYYYMMDD date, got %r" % (label, value))
    return datetime.date(int(text[:4]), int(text[4:6]), int(text[6:]))


def _seconds(value):
    """GTFS HH:MM:SS to seconds from service-day midnight (hours may pass 24)."""
    hours, minutes, seconds = value.strip().split(":")
    return int(hours) * 3600 + int(minutes) * 60 + int(seconds)


def _stop_code(stop_id, codes):
    """Stop code of one stop_id: ``stop_code``, else the second dotted part.

    ``1.111`` (Hospital de Bellvitge) and ``2.7.674433`` (Pl Universitat) put
    the code the app knows in the second part; only a malformed id falls back to
    its last part.
    """
    code = codes.get(stop_id)
    if code is not None:
        return code
    parts = stop_id.split(".")
    for part in (parts[1:2] + parts[::-1]):
        if part.isdigit():
            return int(part)
    raise BuildError("cannot read a stop code from stop_id " + stop_id)


def _stop_codes(archive):
    codes = {}
    for row in _rows(archive, "stops.txt"):
        code = _int(row.get("stop_code"))
        if code is not None:
            codes[row["stop_id"]] = code
    return codes


def _frequencies(archive):
    """trip_id -> [(start_sec, end_sec, headway_secs)] for frequency-based trips."""
    frequencies = {}
    for row in _optional_rows(archive, "frequencies.txt"):
        start = _seconds(row["start_time"])
        end = _seconds(row["end_time"])
        headway = _int(row["headway_secs"])
        if headway and headway > 0:
            frequencies.setdefault(row["trip_id"], []).append((start, end, headway))
    return frequencies


def _lines(archive, only):
    """The lines to write, keyed by (mode, code), plus route_id -> line."""
    lines = {}
    route_ids = []
    for row in _rows(archive, "routes.txt"):
        mode = MODES.get(_int(row.get("route_type")))
        if mode is None:
            continue
        parts = row["route_id"].split(".")
        if len(parts) < 2 or not parts[1].isdigit():
            raise BuildError("unexpected route_id, no line code: " + row["route_id"])
        key = (mode, int(parts[1]))
        line = lines.get(key)
        if line is None:
            line = {
                "mode": mode,
                "code": key[1],
                "name": (row.get("route_short_name") or row["route_id"]).strip(),
                "directions": {},
            }
            lines[key] = line
        route_ids.append((row["route_id"], key))
    if not lines:
        raise BuildError("no metro, bus or funicular line to write")
    missing = sorted(only - set(lines)) if only else []
    if missing:
        raise BuildError(
            "--only matched no line: " + ", ".join("%s:%d" % key for key in missing)
        )
    if only:
        lines = {key: line for key, line in lines.items() if key in only}
    return lines, {route_id: lines[key] for route_id, key in route_ids if key in lines}


def _trips(archive, route_line):
    """trip_id -> (direction state, service_id) for the trips of kept lines."""
    trips = {}
    for row in _rows(archive, "trips.txt"):
        line = route_line.get(row["route_id"])
        if line is None:
            continue
        direction_id = _int(row.get("direction_id"))
        state = line["directions"].get(direction_id)
        if state is None:
            state = {
                "headsigns": collections.Counter(),
                "patterns": {},
                "services": {},
            }
            line["directions"][direction_id] = state
        headsign = (row.get("trip_headsign") or "").strip()
        if headsign:
            state["headsigns"][headsign] += 1
        trips[row["trip_id"]] = (state, row["service_id"].strip())
    return trips


# --- calendar ---------------------------------------------------------------


def _feed_info(archive):
    """(start, end, version) of feed_info.txt, or (None, None, "")."""
    for row in _optional_rows(archive, "feed_info.txt"):
        start = (row.get("feed_start_date") or "").strip()
        end = (row.get("feed_end_date") or "").strip()
        if len(start) == 8 and len(end) == 8 and start.isdigit() and end.isdigit():
            version = (row.get("feed_version") or "").strip()
            return _date(start, "feed_start_date"), _date(end, "feed_end_date"), version
    return None, None, ""


def _calendar_range(calendar, exceptions):
    """Fallback feed range when feed_info.txt has no usable dates."""
    edges = []
    for row in calendar:
        edges.append(row["start_date"].strip())
        edges.append(row["end_date"].strip())
    edges.extend(row["date"].strip() for row in exceptions)
    if not edges:
        raise BuildError("the feed has no calendar and no calendar_dates")
    return _date(min(edges), "calendar start"), _date(max(edges), "calendar end")


WEEKDAYS = ("monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday")


def _services_by_date(calendar, exceptions, dates):
    """date text -> frozenset of service_ids active that day."""
    weekdays = {date: _date(date, "date").weekday() for date in dates}
    active = {date: set() for date in dates}
    for row in calendar:
        start = row["start_date"].strip()
        end = row["end_date"].strip()
        flags = {index for index, day in enumerate(WEEKDAYS) if row[day].strip() == "1"}
        service = row["service_id"].strip()
        for date in dates:
            if start <= date <= end and weekdays[date] in flags:
                active[date].add(service)
    for row in exceptions:
        date = row["date"].strip()
        if date not in active:
            continue
        service = row["service_id"].strip()
        if row["exception_type"].strip() == "1":
            active[date].add(service)
        else:
            active[date].discard(service)
    return {date: frozenset(services) for date, services in active.items()}


def _date_texts(from_date, to_date, feed_start, feed_end):
    """The date texts to write: the feed range narrowed by --from/--to-date."""
    start = max(_date(from_date, "--from-date") if from_date else feed_start, feed_start)
    end = min(_date(to_date, "--to-date") if to_date else feed_end, feed_end)
    if start > end:
        raise BuildError(
            "the requested range is outside the feed range %s..%s"
            % (feed_start.strftime("%Y%m%d"), feed_end.strftime("%Y%m%d"))
        )
    dates = []
    day = start
    while day <= end:
        dates.append(day.strftime("%Y%m%d"))
        day += datetime.timedelta(days=1)
    return dates


# --- stop_times -> patterns -------------------------------------------------


def _fill_times(arrivals, departures):
    """Interpolate the untimed stops of one trip in place; False when it has none.

    The bus half of the feed leaves ``arrival_time``/``departure_time`` empty on
    intermediate stops and times only the first and last one, so a stop between
    timed neighbours gets a straight-line share of that span, and a stop outside
    them copies the nearest timed value.
    """
    timed = [index for index, arrival in enumerate(arrivals) if arrival is not None]
    if not timed:
        return False
    first, last = timed[0], timed[-1]
    for index in range(first):
        arrivals[index] = departures[index] = arrivals[first]
    for index in range(last + 1, len(arrivals)):
        arrivals[index] = departures[index] = departures[last]
    for index in range(len(timed) - 1):
        left, right = timed[index], timed[index + 1]
        span = right - left
        for step in range(1, span):
            fraction = step / span
            arrivals[left + step] = round(
                arrivals[left] + fraction * (arrivals[right] - arrivals[left])
            )
            departures[left + step] = round(
                departures[left] + fraction * (departures[right] - departures[left])
            )
    return True


def _store_trip(trip_id, rows, trips, frequencies, codes):
    """Turn one trip's stop_times rows into a pattern and its start times."""
    trip = trips.get(trip_id)
    if trip is None:
        return False
    state, service_id = trip
    rows.sort(key=lambda row: row[0])
    stops = []
    arrivals = []
    departures = []
    for _, arrival, departure, stop_id in rows:
        start = _seconds(arrival) if arrival else None
        end = _seconds(departure) if departure else None
        stops.append(_stop_code(stop_id, codes))
        arrivals.append(start if start is not None else end)
        departures.append(end if end is not None else start)
    if not stops or not _fill_times(arrivals, departures):
        return False
    base = arrivals[0]
    key = (
        tuple(stops),
        tuple(arrival - base for arrival in arrivals),
        tuple(departure - base for departure in departures),
    )
    pattern = state["patterns"].get(key)
    if pattern is None:
        pattern = len(state["patterns"])
        state["patterns"][key] = pattern
    ranges = frequencies.get(trip_id)
    if ranges is None:
        starts = [departures[0]]
    else:
        starts = [
            start + step * headway
            for start, end, headway in ranges
            for step in range((end - start + headway - 1) // headway)
        ]
    entries = state["services"].setdefault(service_id, [])
    for start in starts:
        entries.append((start, pattern))
    return True


def _patterns(archive, trips, frequencies, codes):
    """Stream stop_times.txt once; return how many kept trips had no time at all."""
    current = None
    rows = []
    stored = set()
    kept = 0
    for row in _rows(archive, "stop_times.txt"):
        trip_id = row["trip_id"]
        if trip_id != current:
            if current is not None:
                kept += 1 if _store_trip(current, rows, trips, frequencies, codes) else 0
                stored.add(current)
            if trip_id in stored:
                raise BuildError("stop_times.txt is not grouped by trip_id")
            current = trip_id
            rows = []
        rows.append(
            (
                _int(row["stop_sequence"]) or 0,
                row["arrival_time"].strip(),
                row["departure_time"].strip(),
                row["stop_id"].strip(),
            )
        )
    if current is not None:
        kept += 1 if _store_trip(current, rows, trips, frequencies, codes) else 0
    return kept


def _sort_patterns(line):
    """Put every direction's patterns in one canonical order and remap indices."""
    for state in line["directions"].values():
        insertion = list(state["patterns"])  # insertion order == pattern index
        ordered = sorted(insertion)
        position = {key: index for index, key in enumerate(ordered)}
        remap = [position[key] for key in insertion]
        state["patterns"] = [
            {"stops": list(key[0]), "arr": list(key[1]), "dep": list(key[2])}
            for key in ordered
        ]
        state["services"] = {
            service_id: [(start, remap[pattern]) for start, pattern in entries]
            for service_id, entries in state["services"].items()
        }


# --- pack assembly ----------------------------------------------------------


def _headsign(state):
    """The most frequent headsign of a direction, ties broken by name."""
    counts = state["headsigns"]
    if not counts:
        return ""
    return sorted(counts.items(), key=lambda item: (-item[1], item[0]))[0][0]


def _line_payload(line, dates, services_by_date):
    """The per-line file: dates -> day type, then the runs of each direction."""
    directions = line["directions"]
    service_ids = {
        direction_id: sorted(state["services"])
        for direction_id, state in directions.items()
    }
    line_services = frozenset(
        service for state in directions.values() for service in state["services"]
    )
    fingerprints = {}

    def fingerprint(direction_id, service_id):
        key = (direction_id, service_id)
        digest = fingerprints.get(key)
        if digest is None:
            sha = hashlib.sha256()
            for start, pattern in sorted(directions[direction_id]["services"][service_id]):
                sha.update(("%d,%d;" % (start, pattern)).encode("ascii"))
            digest = sha.hexdigest()
            fingerprints[key] = digest
        return digest

    day_type_of = {}
    day_type_services = []
    date_of_day_type = {}
    for date in dates:
        active = services_by_date.get(date, frozenset()) & line_services
        if not active:
            continue
        signature = tuple(
            sorted(
                fingerprint(direction_id, service)
                for direction_id in sorted(directions)
                for service in service_ids[direction_id]
                if service in active
            )
        )
        day_type = day_type_of.get(signature)
        if day_type is None:
            day_type = len(day_type_of)
            day_type_of[signature] = day_type
            day_type_services.append(active)
        date_of_day_type[date] = day_type

    payload_directions = []
    for direction_id in sorted(directions):
        state = directions[direction_id]
        day_types = []
        for active in day_type_services:
            runs = []
            for service, entries in state["services"].items():
                if service in active:
                    runs.extend(entries)
            runs.sort()
            day_types.append([[start, pattern] for start, pattern in runs])
        payload_directions.append(
            {
                "id": direction_id,
                "headsign": _headsign(state),
                "patterns": state["patterns"],
                "dayTypes": day_types,
            }
        )
    return {
        "v": PACK_VERSION,
        "mode": line["mode"],
        "code": line["code"],
        "name": line["name"],
        "dates": date_of_day_type,
        "directions": payload_directions,
    }


def _dump(payload):
    """Compact, deterministic JSON bytes: sorted keys, no spaces, one newline."""
    text = json.dumps(payload, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
    return (text + "\n").encode("utf-8")


def _write(out_dir, name, payload):
    data = _dump(payload)
    with open(os.path.join(out_dir, name), "wb") as handle:
        handle.write(data)
    return len(data)


def build(
    feed,
    out_dir,
    only=None,
    from_date=None,
    to_date=None,
    generated_at=None,
    log=print,
):
    """Reduce one GTFS archive (bytes) to the pack; return its file sizes."""
    started = time.monotonic()
    archive = zipfile.ZipFile(io.BytesIO(feed))
    missing = [member for member in REQUIRED_MEMBERS if member not in archive.namelist()]
    if missing:
        raise BuildError("missing member in the GTFS archive: " + ", ".join(missing))

    calendar = list(_optional_rows(archive, "calendar.txt"))
    exceptions = list(_optional_rows(archive, "calendar_dates.txt"))
    feed_start, feed_end, feed_version = _feed_info(archive)
    if feed_start is None:
        feed_start, feed_end = _calendar_range(calendar, exceptions)
    dates = _date_texts(from_date, to_date, feed_start, feed_end)
    services_by_date = _services_by_date(calendar, exceptions, dates)

    lines, route_line = _lines(archive, only)
    trips = _trips(archive, route_line)
    codes = _stop_codes(archive)
    frequencies = _frequencies(archive)
    kept = _patterns(archive, trips, frequencies, codes)
    for line in lines.values():
        _sort_patterns(line)

    timezone = DEFAULT_TIMEZONE
    for row in _optional_rows(archive, "agency.txt"):
        if (row.get("agency_timezone") or "").strip():
            timezone = row["agency_timezone"].strip()
            break

    os.makedirs(out_dir, exist_ok=True)
    sizes = {}
    index_lines = []
    for key in sorted(lines):
        line = lines[key]
        payload = _line_payload(line, dates, services_by_date)
        # A line with no run at all, or with no date in the window, cannot be
        # used by the app: leave it out of the pack and out of the index.
        if not payload["dates"] or not any(
            direction["patterns"] for direction in payload["directions"]
        ):
            continue
        name = "%s-%d.json" % (line["mode"], line["code"])
        sizes[name] = _write(out_dir, name, payload)
        index_lines.append(
            {
                "mode": line["mode"],
                "code": line["code"],
                "name": line["name"],
                "file": name,
            }
        )
    if not index_lines:
        raise BuildError("no line has any trip in the requested dates")
    index = {
        "v": PACK_VERSION,
        "generatedAt": generated_at
        or datetime.datetime.now(datetime.timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z"),
        "feedVersion": feed_version,
        "feedStart": dates[0],
        "feedEnd": dates[-1],
        "timezone": timezone,
        "lines": index_lines,
    }
    sizes["index.json"] = _write(out_dir, "index.json", index)

    modes = collections.Counter(line["mode"] for line in lines.values())
    log(
        "feedVersion %s, feedStart %s, feedEnd %s, %d dates"
        % (feed_version or "<none>", dates[0], dates[-1], len(dates))
    )
    log(
        "lines %d (%s), trips %d of %d timed, patterns %d"
        % (
            len(index_lines),
            ", ".join("%s %d" % (mode, modes[mode]) for mode in sorted(modes)),
            kept,
            len(trips),
            sum(
                len(direction["patterns"])
                for line in lines.values()
                for direction in line["directions"].values()
            ),
        )
    )
    return sizes, time.monotonic() - started


def _report(sizes, elapsed):
    total = sum(sizes.values())
    largest = sorted(sizes, key=lambda name: (-sizes[name], name))[:10]
    for name in largest:
        print("  %-24s %9d bytes" % (name, sizes[name]))
    rest = total - sum(sizes[name] for name in largest)
    if rest:
        print(
            "  %-24s %9d bytes"
            % ("(other %d files)" % (len(sizes) - len(largest)), rest)
        )
    print(
        "schedule pack: %d files, %d bytes (%.2f MB) in %.1f s"
        % (len(sizes), total, total / 1048576, elapsed)
    )
    if total >= SIZE_BUDGET:
        print("warning: the pack is over the %d byte budget" % SIZE_BUDGET)


# --- command line -----------------------------------------------------------


def _parse_only(values):
    """Parse repeated ``--only MODE:CODE`` into a set of (mode, code)."""
    only = set()
    for value in values:
        mode, _, code = value.partition(":")
        if mode not in MODES.values() or not code.isdigit():
            raise BuildError(
                "--only wants MODE:CODE with MODE one of %s, got %r"
                % (", ".join(sorted(MODES.values())), value)
            )
        only.add((mode, int(code)))
    return only


def _feed_bytes(zip_path):
    """The GTFS archive bytes, read from --zip or downloaded from the API."""
    if zip_path:
        try:
            with open(zip_path, "rb") as handle:
                return handle.read()
        except OSError as error:
            raise BuildError("cannot read --zip %s: %s" % (zip_path, error.strerror)) from None
    app_id = os.environ.get("TMB_APP_ID", "")
    app_key = os.environ.get("TMB_APP_KEY", "")
    if not app_id or not app_key:
        raise BuildError(
            "downloading the feed needs TMB_APP_ID and TMB_APP_KEY in the environment"
        )
    query = urllib.parse.urlencode({"app_id": app_id, "app_key": app_key})
    try:
        with urllib.request.urlopen(FEED_URL + "?" + query, timeout=180) as response:
            feed = response.read()
    except urllib.error.HTTPError as error:
        # The request URL carries the credentials: never echo it.
        raise BuildError("download failed: HTTP %d" % error.code) from None
    except urllib.error.URLError as error:
        raise BuildError("download failed: %s" % type(error.reason).__name__) from None
    except OSError as error:
        raise BuildError("download failed: %s" % type(error).__name__) from None
    if not feed.startswith(b"PK"):
        raise BuildError("download did not return a zip archive")
    return feed


def main(argv=None):
    parser = argparse.ArgumentParser(
        prog="build-schedule-pack.py",
        description="Build the compact schedule pack from TMB's static GTFS feed.",
    )
    parser.add_argument("--out", required=True, metavar="DIR", help="output folder")
    parser.add_argument(
        "--zip", metavar="PATH", help="local GTFS zip; downloaded when absent"
    )
    parser.add_argument(
        "--from-date", metavar="YYYYMMDD", help="first date to write (default: feed start)"
    )
    parser.add_argument(
        "--to-date", metavar="YYYYMMDD", help="last date to write (default: feed end)"
    )
    parser.add_argument(
        "--only",
        metavar="MODE:CODE",
        action="append",
        default=[],
        help="write only this line, e.g. metro:1; repeatable",
    )
    parser.add_argument(
        "--generated-at",
        metavar="ISO8601",
        help="timestamp for index.json (default: now, UTC)",
    )
    args = parser.parse_args(argv)
    try:
        only = _parse_only(args.only)
        sizes, elapsed = build(
            _feed_bytes(args.zip),
            args.out,
            only=only,
            from_date=args.from_date,
            to_date=args.to_date,
            generated_at=args.generated_at,
        )
    except BuildError as error:
        print("build-schedule-pack: error: %s" % error, file=sys.stderr)
        return 1
    except (OSError, ValueError, KeyError, csv.Error, zipfile.BadZipFile) as error:
        print(
            "build-schedule-pack: error: %s: %s" % (type(error).__name__, error),
            file=sys.stderr,
        )
        return 1
    _report(sizes, elapsed)
    return 0


if __name__ == "__main__":
    sys.exit(main())
