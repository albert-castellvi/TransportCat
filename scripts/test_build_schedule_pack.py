#!/usr/bin/env python3
"""Tests for scripts/build-schedule-pack.py.

Run from the repository root with:

    python3 -m unittest scripts/test_build_schedule_pack.py

The fixture is a tiny synthetic GTFS archive built in memory: one metro line
with two directions, a shared pattern, an after-midnight trip, an untimed
intermediate stop, a frequencies row, a bus line whose schedules come from a
weekday service and from an exception-only service, and a route type the
builder must ignore.
"""

import contextlib
import importlib.util
import io
import json
import os
import pathlib
import tempfile
import unittest
import unittest.mock
import zipfile

BUILDER_PATH = pathlib.Path(__file__).with_name("build-schedule-pack.py")


def _load_builder():
    """Import the builder by path: its file name holds a dash."""
    spec = importlib.util.spec_from_file_location("build_schedule_pack", BUILDER_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


builder = _load_builder()

GENERATED_AT = "2026-11-01T00:00:00Z"

BASE_MEMBERS = {
    "feed_info.txt": (
        "feed_publisher_name,feed_publisher_url,feed_lang,feed_start_date,"
        "feed_end_date,feed_version\n"
        "TMB,https://www.tmb.cat,ca,20261102,20261108,test-feed-1\n"
    ),
    "agency.txt": (
        "agency_name,agency_url,agency_timezone\nTMB,https://www.tmb.cat,Europe/Madrid\n"
    ),
    "routes.txt": (
        "route_id,route_short_name,route_long_name,route_type,route_url,"
        "route_color,route_text_color\n"
        "1.1.1,L1,Hospital de Bellvitge - Fondo,1,https://www.tmb.cat/metro/L1,CE1126,FFFFFF\n"
        '2.212.2997,H12,"Gornal / Besòs Verneda",3,https://www.tmb.cat/bus/H12,003888,FFFFFF\n'
        "4.9.1,NO,Not a supported mode,4,,,\n"
    ),
    "stops.txt": (
        "stop_id,stop_code,stop_name,stop_lat,stop_lon,stop_url,location_type,"
        "parent_station,wheelchair_boarding\n"
        "1.111,111,Hospital de Bellvitge,41.34,2.10,,0,,1\n"
        "1.112,112,Bellvitge,41.35,2.11,,0,,1\n"
        "1.113,113,Av. Carrilet,41.36,2.12,,0,,1\n"
        "2.3225.674433,3225,Besòs Verneda,41.42,2.20,,0,,0\n"
        "2.91.679467,91,Gornal,41.40,2.19,,0,,0\n"
        "2.150.674500,150,Guipúscoa,41.41,2.19,,0,,0\n"
        "2.200.674600,200,Verneda,41.42,2.20,,0,,0\n"
        "E.1011101,11101,Ascensor,41.34,2.10,,2,P.6660111,1\n"
    ),
    "calendar.txt": (
        "service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,"
        "start_date,end_date\n"
        "WK,1,1,1,1,1,0,0,20261102,20261106\n"
        "SAT,0,0,0,0,0,1,1,20261102,20261108\n"
    ),
    "calendar_dates.txt": (
        "service_id,date,exception_type\nWK,20261104,2\nEX,20261104,1\n"
    ),
    "trips.txt": (
        "route_id,service_id,trip_id,trip_headsign,direction_id,shape_id,"
        "wheelchair_accessible\n"
        "1.1.1,WK,m1,Fondo,0,,1\n"
        "1.1.1,WK,m2,Fondo,0,,1\n"
        "1.1.1,WK,m3,Fondo,0,,1\n"
        "1.1.1,WK,m4,Hospital de Bellvitge,1,,1\n"
        "1.1.1,SAT,m5,Fondo,0,,1\n"
        "2.212.2997,WK,b1,Gornal,0,,0\n"
        '2.212.2997,EX,b2,"Besòs, Verneda",1,,0\n'
        "2.212.2997,WK,b3,Gornal,0,,0\n"
    ),
    "stop_times.txt": (
        "trip_id,arrival_time,departure_time,stop_id,stop_sequence\n"
        "m1,06:00:00,06:00:00,1.111,1\n"
        "m1,06:02:00,06:02:30,1.112,2\n"
        "m1,06:04:00,06:04:00,1.113,3\n"
        "m2,06:10:00,06:10:00,1.111,1\n"
        "m2,06:12:00,06:12:30,1.112,2\n"
        "m2,06:14:00,06:14:00,1.113,3\n"
        "m3,24:10:00,24:10:00,1.111,1\n"
        "m3,24:12:00,24:14:00,1.112,2\n"
        "m3,24:16:00,24:16:00,1.113,3\n"
        "m4,06:05:00,06:05:00,1.113,1\n"
        "m4,06:07:00,06:07:00,1.112,2\n"
        "m4,06:09:00,06:09:00,1.111,3\n"
        "m5,07:00:00,07:00:00,1.111,1\n"
        "m5,07:03:00,07:03:00,1.113,2\n"
        "b1,08:00:00,08:00:00,2.3225.674433,1\n"
        "b1,,,2.150.674500,2\n"
        "b1,,,2.200.674600,3\n"
        "b1,08:30:00,08:30:00,2.91.679467,4\n"
        "b2,09:00:00,09:00:00,2.91.679467,1\n"
        "b2,09:10:00,09:10:00,2.3225.674433,2\n"
        "b3,00:00:00,00:00:00,2.3225.674433,1\n"
        "b3,00:10:00,00:10:00,2.91.679467,2\n"
    ),
    "frequencies.txt": "trip_id,start_time,end_time,headway_secs\nb3,07:00:00,08:00:00,1800\n",
}


def make_feed(members=None, drop=()):
    """Zip the synthetic feed in memory, with optional overrides and drops."""
    files = dict(BASE_MEMBERS)
    files.update(members or {})
    for name in drop:
        files.pop(name, None)
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as archive:
        for name, text in files.items():
            archive.writestr(name, text)
    return buffer.getvalue()


def canonical(payload):
    """The exact bytes the builder must write for one payload."""
    text = json.dumps(payload, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
    return (text + "\n").encode("utf-8")


L1_PATTERNS = [
    {"stops": [111, 112, 113], "arr": [0, 120, 240], "dep": [0, 150, 240]},
    {"stops": [111, 112, 113], "arr": [0, 120, 360], "dep": [0, 240, 360]},
    {"stops": [111, 113], "arr": [0, 180], "dep": [0, 180]},
]

EXPECTED = {
    "index.json": {
        "v": 1,
        "generatedAt": GENERATED_AT,
        "feedVersion": "test-feed-1",
        "feedStart": "20261102",
        "feedEnd": "20261108",
        "timezone": "Europe/Madrid",
        "lines": [
            {"mode": "bus", "code": 212, "name": "H12", "file": "bus-212.json"},
            {"mode": "metro", "code": 1, "name": "L1", "file": "metro-1.json"},
        ],
    },
    "metro-1.json": {
        "v": 1,
        "mode": "metro",
        "code": 1,
        "name": "L1",
        # 20261104 has no metro service (WK is removed and EX has only bus
        # trips), so it is omitted; every other weekday shares day type 0 and
        # the weekend shares day type 1.
        "dates": {
            "20261102": 0,
            "20261103": 0,
            "20261105": 0,
            "20261106": 0,
            "20261107": 1,
            "20261108": 1,
        },
        "directions": [
            {
                "id": 0,
                "headsign": "Fondo",
                "patterns": L1_PATTERNS,
                "dayTypes": [
                    # m1 and m2 share pattern 0; m3 starts after midnight.
                    [[21600, 0], [22200, 0], [87000, 1]],
                    [[25200, 2]],
                ],
            },
            {
                "id": 1,
                "headsign": "Hospital de Bellvitge",
                "patterns": [
                    {"stops": [113, 112, 111], "arr": [0, 120, 240], "dep": [0, 120, 240]}
                ],
                "dayTypes": [[[21900, 0]], []],
            },
        ],
    },
    "bus-212.json": {
        "v": 1,
        "mode": "bus",
        "code": 212,
        "name": "H12",
        # The weekday service of the weekend dates has no bus trips, so those
        # dates are omitted; 20261104 runs on the exception-only service.
        "dates": {
            "20261102": 0,
            "20261103": 0,
            "20261104": 1,
            "20261105": 0,
            "20261106": 0,
        },
        "directions": [
            {
                "id": 0,
                "headsign": "Gornal",
                "patterns": [
                    {"stops": [3225, 91], "arr": [0, 600], "dep": [0, 600]},
                    {
                        # Two untimed intermediates spread over the 30 min span.
                        "stops": [3225, 150, 200, 91],
                        "arr": [0, 600, 1200, 1800],
                        "dep": [0, 600, 1200, 1800],
                    },
                ],
                "dayTypes": [
                    [[25200, 0], [27000, 0], [28800, 1]],
                    [],
                ],
            },
            {
                "id": 1,
                "headsign": "Besòs, Verneda",
                "patterns": [
                    {"stops": [91, 3225], "arr": [0, 600], "dep": [0, 600]}
                ],
                "dayTypes": [[], [[32400, 0]]],
            },
        ],
    },
}


class BuilderTest(unittest.TestCase):
    def run_builder(self, *extra, feed=None):
        """Run the CLI on the given feed; return (code, stdout, stderr, files)."""
        with tempfile.TemporaryDirectory() as scratch:
            out = os.path.join(scratch, "pack")
            arguments = ["--out", out]
            if feed is not None:
                path = os.path.join(scratch, "feed.zip")
                with open(path, "wb") as handle:
                    handle.write(feed)
                arguments += ["--zip", path]
            arguments += list(extra)
            stdout = io.StringIO()
            stderr = io.StringIO()
            with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                code = builder.main(arguments)
            files = {}
            if os.path.isdir(out):
                for name in sorted(os.listdir(out)):
                    with open(os.path.join(out, name), "rb") as handle:
                        files[name] = handle.read()
            return code, stdout.getvalue(), stderr.getvalue(), files

    def test_writes_the_expected_pack(self):
        code, stdout, stderr, files = self.run_builder(
            "--generated-at", GENERATED_AT, feed=make_feed()
        )
        self.assertEqual((code, stderr), (0, ""))
        self.assertEqual(sorted(files), sorted(EXPECTED))
        for name, payload in EXPECTED.items():
            with self.subTest(file=name):
                self.assertEqual(json.loads(files[name]), payload)
                self.assertEqual(files[name], canonical(payload))
        # The report names the feed identity and the pack size.
        self.assertIn("feedVersion test-feed-1", stdout)
        self.assertIn("feedStart 20261102", stdout)
        self.assertIn("feedEnd 20261108", stdout)
        self.assertIn("schedule pack: 3 files, %d bytes" % sum(map(len, files.values())), stdout)

    def test_only_keeps_one_line(self):
        code, _, stderr, files = self.run_builder(
            "--generated-at", GENERATED_AT, "--only", "metro:1", feed=make_feed()
        )
        self.assertEqual((code, stderr), (0, ""))
        self.assertEqual(sorted(files), ["index.json", "metro-1.json"])
        index = json.loads(files["index.json"])
        self.assertEqual([line["code"] for line in index["lines"]], [1])

    def test_unknown_only_line_fails(self):
        code, _, stderr, files = self.run_builder("--only", "metro:99", feed=make_feed())
        self.assertEqual(code, 1)
        self.assertIn("--only matched no line: metro:99", stderr)
        self.assertEqual(files, {})

    def test_bad_only_syntax_fails(self):
        code, _, stderr, _ = self.run_builder("--only", "tram:1", feed=make_feed())
        self.assertEqual(code, 1)
        self.assertIn("--only wants MODE:CODE", stderr)

    def test_date_window_without_service_drops_the_line(self):
        code, _, stderr, files = self.run_builder(
            "--generated-at",
            GENERATED_AT,
            "--from-date",
            "20261104",
            "--to-date",
            "20261104",
            feed=make_feed(),
        )
        self.assertEqual((code, stderr), (0, ""))
        self.assertEqual(sorted(files), ["bus-212.json", "index.json"])
        index = json.loads(files["index.json"])
        self.assertEqual((index["feedStart"], index["feedEnd"]), ("20261104", "20261104"))
        self.assertEqual(list(json.loads(files["bus-212.json"])["dates"]), ["20261104"])

    def test_window_outside_the_feed_fails(self):
        code, _, stderr, _ = self.run_builder(
            "--from-date", "20270101", "--to-date", "20270102", feed=make_feed()
        )
        self.assertEqual(code, 1)
        self.assertIn("outside the feed range 20261102..20261108", stderr)

    def test_malformed_date_fails(self):
        code, _, stderr, _ = self.run_builder("--from-date", "2026-11-02", feed=make_feed())
        self.assertEqual(code, 1)
        self.assertIn("--from-date must be a YYYYMMDD date", stderr)

    def test_output_is_deterministic(self):
        first = self.run_builder("--generated-at", GENERATED_AT, feed=make_feed())[3]
        second = self.run_builder("--generated-at", GENERATED_AT, feed=make_feed())[3]
        self.assertEqual(first, second)

    def test_missing_member_fails(self):
        code, _, stderr, _ = self.run_builder(feed=make_feed(drop=["stop_times.txt"]))
        self.assertEqual(code, 1)
        self.assertIn("missing member in the GTFS archive: stop_times.txt", stderr)

    def test_unsupported_route_types_fail(self):
        members = {
            "routes.txt": (
                "route_id,route_short_name,route_long_name,route_type\n"
                "4.9.1,NO,Not a supported mode,4\n"
            )
        }
        code, _, stderr, _ = self.run_builder(feed=make_feed(members=members))
        self.assertEqual(code, 1)
        self.assertIn("no metro, bus or funicular line to write", stderr)

    def test_feed_without_feed_info_falls_back_to_the_calendar(self):
        code, stdout, stderr, files = self.run_builder(
            "--generated-at",
            GENERATED_AT,
            "--only",
            "metro:1",
            feed=make_feed(drop=["feed_info.txt", "agency.txt"]),
        )
        self.assertEqual((code, stderr), (0, ""))
        index = json.loads(files["index.json"])
        self.assertEqual(index["feedVersion"], "")
        self.assertEqual((index["feedStart"], index["feedEnd"]), ("20261102", "20261108"))
        self.assertEqual(index["timezone"], "Europe/Madrid")
        self.assertIn("feedVersion <none>", stdout)

    def test_download_without_credentials_fails_without_leaking(self):
        with unittest.mock.patch.dict(os.environ, {"TMB_APP_ID": "", "TMB_APP_KEY": ""}):
            code, _, stderr, files = self.run_builder("--generated-at", GENERATED_AT)
        self.assertEqual(code, 1)
        self.assertIn("TMB_APP_ID and TMB_APP_KEY", stderr)
        self.assertNotIn("app_id=", stderr)
        self.assertNotIn("http", stderr)
        self.assertEqual(files, {})

    def test_unreadable_zip_fails(self):
        code, _, stderr, _ = self.run_builder("--zip", "/nonexistent/gtfs.zip")
        self.assertEqual(code, 1)
        self.assertIn("cannot read --zip", stderr)

    def test_not_a_zip_fails(self):
        code, _, stderr, _ = self.run_builder(feed=b"definitely not a zip archive")
        self.assertEqual(code, 1)
        self.assertIn("BadZipFile", stderr)


if __name__ == "__main__":
    unittest.main()
