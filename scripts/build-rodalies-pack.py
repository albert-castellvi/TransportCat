#!/usr/bin/env python3
"""Build the Rodalies de Catalunya data files from Renfe's static GTFS.

Python 3 standard library only. Two outputs from the same download:

``rodalies-topology.json``
    Small, committed to the repository and bundled in the app: the lines (code,
    long name, colour and a readable text colour), the stations (id, name,
    coordinates, the line codes serving them, accessibility) and, per line and
    direction, the ordered station ids plus the polyline (simplified).

``rodalies-schedule.json.gz``
    Larger, published by CI as a release asset and never committed: for every
    service date in the feed, every station's departures (line, direction,
    destination, seconds from midnight, trip id) in flat integer arrays over
    shared string tables.

Source: ``https://ssl.renfe.com/ftransit/Fichero_CER_FOMENTO/fomento_transit.zip``
(Renfe open data, CC BY 4.0, no key), reissued daily with a rolling window.

Nucleus: the Catalonia routes are the ones whose ``route_id`` starts with
``51T`` (the Barcelona network); every other prefix in the feed belongs to a
different Spanish nucleus and is ignored.

Direction: the feed has no ``direction_id``. Each line publishes one
``51_<code>`` shape and, usually, a ``51_<code>_INV`` one, but a route's
``shape_id`` is not trustworthy (``RL4`` uses the forward shape both ways and
``R13`` has two routes on it), so the direction of a route is derived from
geometry: its first and last stops are projected onto the forward shape, and
the route runs forward when the first stop projects before the last one.
"""

import argparse
import collections
import csv
import datetime
import gzip
import io
import json
import math
import os
import re
import sys
import time
import urllib.error
import urllib.request
import zipfile

FEED_URL = "https://ssl.renfe.com/ftransit/Fichero_CER_FOMENTO/fomento_transit.zip"
# Renfe's Catalonia nucleus. Every other route prefix is a different network.
NUCLEUS_ROUTE_PREFIX = "51T"
PACK_VERSION = 1
DEFAULT_TIMEZONE = "Europe/Madrid"
TOPOLOGY_FILE = "rodalies-topology.json"
SCHEDULE_FILE = "rodalies-schedule.json.gz"
# The bundled topology ships inside the app binary; keep it small.
TOPOLOGY_SIZE_BUDGET = 1024 * 1024
# Douglas-Peucker tolerance in meters for the shapes.
DEFAULT_SIMPLIFY_METERS = 12.0
REQUIRED_MEMBERS = ("routes.txt", "stops.txt", "trips.txt", "stop_times.txt")


class BuildError(Exception):
    """A failure reported as one clear line and a non-zero exit code."""


# --- GTFS reading -----------------------------------------------------------


def _rows(archive, member):
    """Yield the rows of one archive member as dicts, headers and values trimmed.

    Renfe pads both the header names and the values with spaces
    (``route_text_color                ``), so every key and value is stripped
    before use. Streamed: ``stop_times.txt`` is 275 MB.
    """
    if member not in archive.namelist():
        raise BuildError("missing member in the GTFS archive: " + member)
    with archive.open(member) as handle:
        text = io.TextIOWrapper(handle, encoding="utf-8-sig", newline="")
        reader = csv.DictReader(text)
        reader.fieldnames = [(name or "").strip() for name in reader.fieldnames or []]
        for row in reader:
            yield {key: (value or "").strip() for key, value in row.items() if key}


def _optional_rows(archive, member):
    """Yield the rows of a member that may be absent."""
    if member in archive.namelist():
        yield from _rows(archive, member)


def _int(value):
    """Parse an integer field, tolerating empty strings and stray spaces."""
    text = (value or "").strip()
    return int(text) if text.lstrip("-").isdigit() else None


def _date(value, label):
    """Parse a YYYYMMDD field into a date, or fail with a clear message."""
    text = (value or "").strip()
    if len(text) != 8 or not text.isdigit():
        raise BuildError("%s must be a YYYYMMDD date, got %r" % (label, value))
    return datetime.date(int(text[:4]), int(text[4:6]), int(text[6:]))


def _seconds(value):
    """GTFS HH:MM:SS to seconds from service-day midnight (hours may pass 24)."""
    text = (value or "").strip()
    if not text:
        return None
    parts = text.split(":")
    if len(parts) != 3:
        return None
    try:
        hours, minutes, seconds = (int(part) for part in parts)
    except ValueError:
        return None
    return hours * 3600 + minutes * 60 + seconds


def _clean_name(value):
    """Collapse the feed's padding and normalise the origin-destination dash.

    ``'Molins de Rei      -Maçanet-Massanes   '`` becomes
    ``'Molins de Rei - Maçanet-Massanes'``; hyphens inside a station name
    (``La Tor de Querol-Enveig``) are not touched because the separator is the
    only hyphen the feed pads with spaces.
    """
    text = re.sub(r"\s+", " ", (value or "").strip())
    text = re.sub(r"\s+-\s*", " - ", text)
    text = text.lstrip("- ")
    return text.strip()


def _text_color(color_hex):
    """Black or white, whichever is readable on ``color_hex``.

    The WCAG relative luminance, with the same 0.179 cut as the app's
    ``HexLuminance``: on that threshold black and white text have the same
    contrast, so each side picks the more readable of the two.
    """
    digits = (color_hex or "").upper()
    if len(digits) != 6 or any(c not in "0123456789ABCDEF" for c in digits):
        return "FFFFFF"

    def linearize(channel):
        value = channel / 255
        return value / 12.92 if value <= 0.03928 else ((value + 0.055) / 1.055) ** 2.4

    red = linearize(int(digits[0:2], 16))
    green = linearize(int(digits[2:4], 16))
    blue = linearize(int(digits[4:6], 16))
    return "000000" if 0.2126 * red + 0.7152 * green + 0.0722 * blue > 0.179 else "FFFFFF"


# --- geometry ---------------------------------------------------------------


def _point_distance(a, b):
    """Approximate distance in meters between two (lat, lon) points."""
    lat1, lon1 = math.radians(a[0]), math.radians(a[1])
    lat2, lon2 = math.radians(b[0]), math.radians(b[1])
    dlat = lat2 - lat1
    dlon = (lon2 - lon1) * math.cos((lat1 + lat2) / 2)
    return math.hypot(dlat, dlon) * 6_371_000


def _nearest_along(point, points):
    """Distance in meters along ``points`` to the foot nearest ``point``.

    The projection is done in a local equirectangular plane centred on the
    query point, the same approximation the app's ``GeoMath`` uses; it is only
    needed to order stations and to compare two positions on one shape.
    """
    if not points:
        return 0.0
    if len(points) == 1:
        return _point_distance(point, points[0])
    scale = math.cos(math.radians(point[0]))
    px, py = 0.0, 0.0
    best_distance = 0.0
    best_offset = float("inf")
    travelled = 0.0
    for index in range(len(points) - 1):
        ax = (points[index][1] - point[1]) * 111_320 * scale
        ay = (points[index][0] - point[0]) * 110_540
        bx = (points[index + 1][1] - point[1]) * 111_320 * scale
        by = (points[index + 1][0] - point[0]) * 110_540
        dx, dy = bx - ax, by - ay
        length_squared = dx * dx + dy * dy
        fraction = 0.0 if length_squared == 0 else max(0.0, min(1.0, -(ax * dx + ay * dy) / length_squared))
        foot_x, foot_y = ax + fraction * dx, ay + fraction * dy
        offset = math.hypot(foot_x, foot_y)
        segment = math.hypot(dx, dy)
        if offset < best_offset:
            best_offset = offset
            best_distance = travelled + fraction * segment
        travelled += segment
    return best_distance


def _simplify(points, tolerance_meters):
    """Douglas-Peucker simplification of a (lat, lon) polyline.

    Iterative on purpose: the longest shape in the feed has 3,345 points and a
    recursive pass over a straight run could exceed Python's recursion limit.
    The endpoints always survive, so a simplified shape still starts and ends
    where the original does.
    """
    if len(points) <= 2 or tolerance_meters <= 0:
        return list(points)
    scale = math.cos(math.radians(points[0][0]))
    planar = [
        ((lon - points[0][1]) * 111_320 * scale, (lat - points[0][0]) * 110_540)
        for lat, lon in points
    ]
    keep = [False] * len(points)
    keep[0] = keep[-1] = True
    stack = [(0, len(points) - 1)]
    while stack:
        first, last = stack.pop()
        if last <= first + 1:
            continue
        ax, ay = planar[first]
        bx, by = planar[last]
        dx, dy = bx - ax, by - ay
        length_squared = dx * dx + dy * dy
        farthest = -1
        farthest_offset = 0.0
        for index in range(first + 1, last):
            px, py = planar[index]
            if length_squared == 0:
                offset = math.hypot(px - ax, py - ay)
            else:
                fraction = max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / length_squared))
                offset = math.hypot(px - (ax + fraction * dx), py - (ay + fraction * dy))
            if offset > farthest_offset:
                farthest_offset = offset
                farthest = index
        if farthest > 0 and farthest_offset > tolerance_meters:
            keep[farthest] = True
            stack.append((first, farthest))
            stack.append((farthest, last))
    return [point for point, kept in zip(points, keep) if kept]


def _rounded(points, decimals=5):
    """Coordinates rounded so the JSON stays small and the output stable."""
    return [[round(lat, decimals), round(lon, decimals)] for lat, lon in points]


# --- feed slicing -----------------------------------------------------------


def _routes(archive):
    """The nucleus routes, grouped by line code.

    - Returns: ``(lines, route_line, route_names)`` where ``lines`` maps a line
      code to its entry (colours and its route ids), ``route_line`` maps a
      ``route_id`` to its line code and ``route_names`` keeps the cleaned long
      name of every route (the line takes its own from its busiest route).
    """
    lines = {}
    route_line = {}
    route_names = {}
    for row in _rows(archive, "routes.txt"):
        route_id = row["route_id"]
        if not route_id.startswith(NUCLEUS_ROUTE_PREFIX):
            continue
        code = (row.get("route_short_name") or "").strip()
        if not code:
            raise BuildError("nucleus route without route_short_name: " + route_id)
        line = lines.get(code)
        if line is None:
            line = {
                "code": code,
                "name": "",
                "colorHex": (row.get("route_color") or "").upper(),
                "textColorHex": _text_color((row.get("route_color") or "").upper()),
                "routes": [],
            }
            lines[code] = line
        line["routes"].append(route_id)
        route_line[route_id] = code
        route_names[route_id] = _clean_name(row.get("route_long_name"))
    if not lines:
        raise BuildError("no route with the Catalonia nucleus prefix " + NUCLEUS_ROUTE_PREFIX)
    return lines, route_line, route_names


def _stops(archive):
    """Every stop of the feed: id -> name, point and accessibility."""
    stops = {}
    for row in _rows(archive, "stops.txt"):
        stop_id = row["stop_id"]
        if not stop_id:
            continue
        latitude = _float(row.get("stop_lat"))
        longitude = _float(row.get("stop_lon"))
        stops[stop_id] = {
            "name": (row.get("stop_name") or stop_id).strip(),
            "point": (latitude, longitude) if latitude is not None and longitude is not None else None,
            "wheelchair": _int(row.get("wheelchair_boarding")),
        }
    return stops


def _float(value):
    """Parse a decimal field, tolerating empty strings."""
    text = (value or "").strip()
    if not text:
        return None
    try:
        return float(text)
    except ValueError:
        return None


def _trips(archive, route_line):
    """The trips of the nucleus: trip_id -> route, service, shape and headsign."""
    trips = {}
    for row in _rows(archive, "trips.txt"):
        route_id = row["route_id"]
        if route_line.get(route_id) is None:
            continue
        trip_id = row["trip_id"]
        if not trip_id:
            continue
        trips[trip_id] = {
            "routeId": route_id,
            "serviceId": row.get("service_id", ""),
            "shapeId": row.get("shape_id", ""),
            "headsign": _clean_name(row.get("trip_headsign")),
        }
    if not trips:
        raise BuildError("no trip belongs to the Catalonia nucleus")
    return trips


def _shapes(archive):
    """Every shape as an ordered list of (lat, lon), grouped by shape_id."""
    rows = collections.defaultdict(list)
    for row in _rows(archive, "shapes.txt"):
        shape_id = row.get("shape_id", "")
        latitude = _float(row.get("shape_pt_lat"))
        longitude = _float(row.get("shape_pt_lon"))
        sequence = _int(row.get("shape_pt_sequence"))
        if not shape_id or latitude is None or longitude is None or sequence is None:
            continue
        rows[shape_id].append((sequence, latitude, longitude))
    return {
        shape_id: [(latitude, longitude) for _, latitude, longitude in sorted(entries)]
        for shape_id, entries in rows.items()
    }


def _trip_stops(archive, trips):
    """trip_id -> ordered [(stop_id, arrival_sec, departure_sec)] of the nucleus."""
    rows = collections.defaultdict(list)
    for row in _rows(archive, "stop_times.txt"):
        trip_id = row["trip_id"]
        if trip_id not in trips:
            continue
        sequence = _int(row.get("stop_sequence"))
        stop_id = row.get("stop_id", "")
        if sequence is None or not stop_id:
            continue
        rows[trip_id].append(
            (sequence, stop_id, _seconds(row.get("arrival_time")), _seconds(row.get("departure_time")))
        )
    result = {}
    for trip_id, entries in rows.items():
        entries.sort()
        result[trip_id] = [(stop_id, arrival, departure) for _, stop_id, arrival, departure in entries]
    return result


def _trip_directions(lines, route_line, trips, trip_stops, shapes, stops):
    """Direction (0 forward, 1 reverse) of every trip, from the line's shape.

    The feed has no ``direction_id`` and its ``shape_id`` is not reliable
    (``RL4`` uses the forward shape both ways and an ``R13`` route does too),
    so each trip is projected onto its line's forward shape (``51_<code>``):
    a first stop that projects before the last stop is direction 0. The answer
    only depends on the line and the two end stations, so it is memoised per
    triple instead of recomputed for thousands of trips.
    """
    forward_shapes = {
        code: shapes.get(NUCLEUS_ROUTE_PREFIX.rstrip("T") + "_" + code) or [] for code in lines
    }
    memo = {}
    directions = {}
    for trip_id, trip in trips.items():
        code = route_line[trip["routeId"]]
        entries = trip_stops.get(trip_id) or []
        if len(entries) < 2:
            # A trip the feed ships with no body has no direction to speak of.
            directions[trip_id] = 0
            continue
        key = (code, entries[0][0], entries[-1][0])
        direction = memo.get(key)
        if direction is None:
            points = forward_shapes[code]
            first = stops.get(entries[0][0], {}).get("point")
            last = stops.get(entries[-1][0], {}).get("point")
            if points and first and last:
                direction = 0 if _nearest_along(first, points) <= _nearest_along(last, points) else 1
            else:
                # No shape to compare against: the feed's forward default.
                direction = 0
            memo[key] = direction
        directions[trip_id] = direction
    return directions


def _direction_polylines(lines, shapes):
    """The drawn polyline of each line and direction, from shapes.txt.

    ``51_<code>`` is the forward shape and ``51_<code>_INV`` the reverse one.
    When the reverse shape is missing (the feed has shipped ``RL4`` with both
    trips on the forward shape) the forward one is reversed, which is exact
    because the two shapes are the same track run backwards.
    """
    polylines = {}
    for code in lines:
        base = NUCLEUS_ROUTE_PREFIX.rstrip("T") + "_" + code
        forward = shapes.get(base, [])
        reverse = shapes.get(base + "_INV", [])
        if not reverse and forward:
            reverse = list(reversed(forward))
        polylines[code] = {0: forward, 1: reverse}
    return polylines


# --- calendar ---------------------------------------------------------------


WEEKDAYS = ("monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday")


def _feed_range(archive):
    """The date window of the feed, from calendar.txt (this feed has no feed_info)."""
    edges = []
    for row in _optional_rows(archive, "calendar.txt"):
        edges.append(row.get("start_date", ""))
        edges.append(row.get("end_date", ""))
    for row in _optional_rows(archive, "calendar_dates.txt"):
        edges.append(row.get("date", ""))
    edges = [edge for edge in edges if len(edge) == 8 and edge.isdigit()]
    if not edges:
        raise BuildError("the feed has no calendar and no calendar_dates")
    return _date(min(edges), "calendar start"), _date(max(edges), "calendar end")


def _services_by_date(archive, dates):
    """date text -> frozenset of the service_ids active that day."""
    weekdays = {date: _date(date, "date").weekday() for date in dates}
    active = {date: set() for date in dates}
    for row in _optional_rows(archive, "calendar.txt"):
        start = row.get("start_date", "")
        end = row.get("end_date", "")
        flags = {index for index, day in enumerate(WEEKDAYS) if row.get(day, "") == "1"}
        service = row.get("service_id", "")
        for date in dates:
            if start <= date <= end and weekdays[date] in flags:
                active[date].add(service)
    for row in _optional_rows(archive, "calendar_dates.txt"):
        date = row.get("date", "")
        if date not in active:
            continue
        service = row.get("service_id", "")
        if row.get("exception_type", "") == "1":
            active[date].add(service)
        else:
            active[date].discard(service)
    return {date: frozenset(services) for date, services in active.items()}


def _date_texts(start, end):
    dates = []
    day = start
    while day <= end:
        dates.append(day.strftime("%Y%m%d"))
        day += datetime.timedelta(days=1)
    return dates


# --- payloads ---------------------------------------------------------------


def _natural_key(code):
    """Sort key that orders R1, R2, R2N, R10 as a rider would expect."""
    match = re.match(r"([A-Za-z]*)(\d+)(.*)", code)
    if not match:
        return (code, "", 0, "")
    return (match.group(1), "", int(match.group(2)), match.group(3))


def _topology(lines, route_line, trips, trip_stops, stops, shapes, generated_at, simplify_meters):
    """The bundled topology payload: lines, stations and per-direction geometry."""
    trip_direction = _trip_directions(lines, route_line, trips, trip_stops, shapes, stops)
    polylines = _direction_polylines(lines, shapes)

    line_of_trip = {trip_id: route_line[trip["routeId"]] for trip_id, trip in trips.items()}
    stations_of_line = collections.defaultdict(set)
    stations_of_direction = collections.defaultdict(set)
    trips_of_direction = collections.defaultdict(list)
    for trip_id, entries in trip_stops.items():
        code = line_of_trip[trip_id]
        direction = trip_direction[trip_id]
        trips_of_direction[(code, direction)].append([stop_id for stop_id, _, _ in entries])
        for stop_id, _, _ in entries:
            stations_of_line[code].add(stop_id)
            stations_of_direction[(code, direction)].add(stop_id)

    all_station_ids = set().union(*stations_of_line.values()) if stations_of_line else set()
    station_payload = []
    for stop_id in sorted(all_station_ids):
        stop = stops.get(stop_id)
        if stop is None or stop["point"] is None:
            continue
        codes = sorted(
            (code for code, ids in stations_of_line.items() if stop_id in ids),
            key=_natural_key,
        )
        station_payload.append(
            {
                "id": stop_id,
                "name": stop["name"],
                "lat": round(stop["point"][0], 6),
                "lon": round(stop["point"][1], 6),
                "lines": codes,
                "wheelchair": stop["wheelchair"],
            }
        )

    direction_payload = []
    for code in sorted(lines, key=_natural_key):
        for direction in (0, 1):
            ids = stations_of_direction.get((code, direction), set())
            points = polylines[code][direction]
            if ids and points:
                # Ordered along the direction's own track, so branches and
                # short-turn routes still land in travel order.
                ordered = sorted(
                    ids,
                    key=lambda stop_id: (
                        _nearest_along(stops[stop_id]["point"], points)
                        if stops.get(stop_id, {}).get("point")
                        else 0.0,
                        stop_id,
                    ),
                )
            elif ids:
                # No shape at all: the longest trip of the direction is the
                # backbone, and any other station follows it.
                backbone = max(trips_of_direction.get((code, direction), [[]]), key=len)
                ordered = [stop_id for stop_id in backbone if stop_id in ids]
                ordered += sorted(ids - set(ordered))
            else:
                ordered = []
            if not points:
                # No shape at all: straight segments between the stations, so
                # the map still draws the line and the trains still snap.
                points = [stops[stop_id]["point"] for stop_id in ordered if stops.get(stop_id, {}).get("point")]
            simplified = _simplify(points, simplify_meters)
            direction_payload.append(
                {
                    "line": code,
                    "dir": direction,
                    "stations": ordered,
                    "points": _rounded(simplified),
                }
            )

    line_payload = []
    for code in sorted(lines, key=_natural_key):
        line = lines[code]
        line_payload.append(
            {
                "code": code,
                "name": line["name"],
                "colorHex": line["colorHex"],
                "textColorHex": line["textColorHex"],
            }
        )

    return {
        "v": PACK_VERSION,
        "generatedAt": generated_at,
        "timezone": DEFAULT_TIMEZONE,
        "lines": line_payload,
        "stations": station_payload,
        "directions": direction_payload,
    }, trip_direction


def _schedule(lines, route_line, trips, trip_stops, stops, dates, services_by_date, trip_direction):
    """The published schedule payload: per date, per station, flat departure rows.

    A row is five integers into four shared tables:
    ``[line, direction, seconds, headsign, trip]``. ``seconds`` is the GTFS
    departure time of the service day, so it can pass 86400 for the trains that
    leave after midnight; the app is what folds those back onto the wall clock.
    """
    codes = sorted(lines, key=_natural_key)
    line_index = {code: index for index, code in enumerate(codes)}

    headsigns = []
    headsign_index = {}
    trip_ids = []
    trip_index = {}

    def intern(table, index, value):
        position = index.get(value)
        if position is None:
            position = len(table)
            table.append(value)
            index[value] = position
        return position

    trips_by_service = collections.defaultdict(list)
    for trip_id, trip in trips.items():
        trips_by_service[trip["serviceId"]].append(trip_id)

    days = {}
    for date in dates:
        services = services_by_date.get(date, frozenset())
        if not services:
            continue
        rows_per_station = collections.defaultdict(list)
        for service in services:
            for trip_id in trips_by_service.get(service, ()):
                entries = trip_stops.get(trip_id)
                if not entries or len(entries) < 2:
                    continue
                trip = trips[trip_id]
                code = route_line[trip["routeId"]]
                direction = trip_direction[trip_id]
                destination = trip["headsign"] or stops.get(entries[-1][0], {}).get("name", "")
                headsign = intern(headsigns, headsign_index, destination)
                trip_number = intern(trip_ids, trip_index, trip_id)
                line_number = line_index[code]
                # The last stop has no departure: a board never offers it.
                for stop_id, arrival, departure in entries[:-1]:
                    seconds = departure if departure is not None else arrival
                    if seconds is None:
                        continue
                    rows_per_station[stop_id].extend(
                        [line_number, direction, seconds, headsign, trip_number]
                    )
        if rows_per_station:
            days[date] = {
                station: _sorted_rows(rows)
                for station, rows in sorted(rows_per_station.items())
            }

    if not days:
        raise BuildError("no service date of the feed has any departure")

    return {
        "v": PACK_VERSION,
        "timezone": DEFAULT_TIMEZONE,
        "lines": codes,
        "headsigns": headsigns,
        "trips": trip_ids,
        "dates": sorted(days),
        "days": days,
    }


def _sorted_rows(flat):
    """Sort a flat row array by departure seconds, keeping the rows intact."""
    rows = [tuple(flat[index:index + 5]) for index in range(0, len(flat), 5)]
    rows.sort(key=lambda row: (row[2], row[4]))
    return [value for row in rows for value in row]


def _dump(payload):
    """Compact, deterministic JSON bytes: sorted keys, no spaces, one newline."""
    text = json.dumps(payload, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
    return (text + "\n").encode("utf-8")


def _write_gzip(out_dir, name, data):
    """Atomic-free deterministic gzip write: fixed mtime so reruns compare equal."""
    path = os.path.join(out_dir, name)
    with open(path, "wb") as handle:
        with gzip.GzipFile(fileobj=handle, mode="wb", compresslevel=9, mtime=0, filename="") as archive:
            archive.write(data)
    return os.path.getsize(path)


def _write(out_dir, name, data):
    path = os.path.join(out_dir, name)
    with open(path, "wb") as handle:
        handle.write(data)
    return os.path.getsize(path)


def build(feed, out_dir, generated_at=None, simplify_meters=DEFAULT_SIMPLIFY_METERS, log=print):
    """Reduce one GTFS archive (bytes) to the topology and schedule files."""
    started = time.monotonic()
    archive = zipfile.ZipFile(io.BytesIO(feed))
    missing = [member for member in REQUIRED_MEMBERS if member not in archive.namelist()]
    if missing:
        raise BuildError("missing member in the GTFS archive: " + ", ".join(missing))

    lines, route_line, route_names = _routes(archive)
    trips = _trips(archive, route_line)
    stops = _stops(archive)
    shapes = _shapes(archive)
    trip_stops = _trip_stops(archive, trips)

    # The line's display name: the long name of its busiest route, cleaned.
    trips_per_route = collections.Counter(trip["routeId"] for trip in trips.values())
    for line in lines.values():
        ordered = sorted(line["routes"], key=lambda route_id: (-trips_per_route[route_id], route_id))
        line["name"] = next(
            (route_names[route_id] for route_id in ordered if route_names.get(route_id)),
            line["code"],
        )

    start, end = _feed_range(archive)
    dates = _date_texts(start, end)
    services_by_date = _services_by_date(archive, dates)

    timestamp = generated_at or (
        datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    )
    topology, trip_direction = _topology(
        lines, route_line, trips, trip_stops, stops, shapes, timestamp, simplify_meters
    )
    schedule = _schedule(
        lines, route_line, trips, trip_stops, stops, dates, services_by_date, trip_direction
    )

    os.makedirs(out_dir, exist_ok=True)
    topology_bytes = _dump(topology)
    schedule_bytes = _dump(schedule)
    sizes = {
        TOPOLOGY_FILE: _write(out_dir, TOPOLOGY_FILE, topology_bytes),
        SCHEDULE_FILE: _write_gzip(out_dir, SCHEDULE_FILE, schedule_bytes),
    }
    log(
        "feed %s..%s, %d dates, %d lines, %d stations, %d trips"
        % (start.strftime("%Y%m%d"), end.strftime("%Y%m%d"), len(dates), len(lines),
           len(topology["stations"]), len(trips))
    )
    points = sum(len(direction["points"]) for direction in topology["directions"])
    log(
        "topology: %d bytes, %d direction polylines, %d points after simplification"
        % (sizes[TOPOLOGY_FILE], len(topology["directions"]), points)
    )
    log(
        "schedule: %d bytes gzip (%d bytes json), %d dates"
        % (sizes[SCHEDULE_FILE], len(schedule_bytes), len(schedule["dates"]))
    )
    if sizes[TOPOLOGY_FILE] >= TOPOLOGY_SIZE_BUDGET:
        log("warning: the topology is over the %d byte budget" % TOPOLOGY_SIZE_BUDGET)
    return sizes, time.monotonic() - started


def _report(sizes, elapsed):
    print("  %-28s %9d bytes" % (TOPOLOGY_FILE, sizes[TOPOLOGY_FILE]))
    print("  %-28s %9d bytes" % (SCHEDULE_FILE, sizes[SCHEDULE_FILE]))
    print(
        "rodalies pack: %d bytes (%.2f MB) in %.1f s"
        % (sum(sizes.values()), sum(sizes.values()) / 1048576, elapsed)
    )


# --- command line -----------------------------------------------------------


def _feed_bytes(zip_path):
    """The GTFS archive bytes, read from --zip or downloaded (no key needed)."""
    if zip_path:
        try:
            with open(zip_path, "rb") as handle:
                return handle.read()
        except OSError as error:
            raise BuildError("cannot read --zip %s: %s" % (zip_path, error.strerror)) from None
    try:
        with urllib.request.urlopen(FEED_URL, timeout=300) as response:
            feed = response.read()
    except urllib.error.HTTPError as error:
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
        prog="build-rodalies-pack.py",
        description="Build the Rodalies de Catalunya topology and schedule files from Renfe's GTFS.",
    )
    parser.add_argument("--out", required=True, metavar="DIR", help="output folder")
    parser.add_argument("--zip", metavar="PATH", help="local GTFS zip; downloaded when absent")
    parser.add_argument(
        "--generated-at", metavar="ISO8601", help="timestamp for the topology (default: now, UTC)"
    )
    parser.add_argument(
        "--simplify-meters",
        type=float,
        default=DEFAULT_SIMPLIFY_METERS,
        metavar="M",
        help="Douglas-Peucker tolerance for the shapes (default: 12)",
    )
    args = parser.parse_args(argv)
    try:
        sizes, elapsed = build(
            _feed_bytes(args.zip),
            args.out,
            generated_at=args.generated_at,
            simplify_meters=args.simplify_meters,
        )
    except BuildError as error:
        print("build-rodalies-pack: error: %s" % error, file=sys.stderr)
        return 1
    except (OSError, ValueError, KeyError, csv.Error, zipfile.BadZipFile) as error:
        print(
            "build-rodalies-pack: error: %s: %s" % (type(error).__name__, error),
            file=sys.stderr,
        )
        return 1
    _report(sizes, elapsed)
    return 0


if __name__ == "__main__":
    sys.exit(main())
