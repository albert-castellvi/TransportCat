#!/usr/bin/env python3
"""Tests for scripts/build-rodalies-pack.py.

Run from the repository root with:

    python3 -m unittest scripts/test_build_rodalies_pack.py

The fixture is a tiny synthetic GTFS archive built in memory, shaped like
Renfe's feed: padded header names and values, trailing spaces in
``route_short_name``, no ``direction_id``, a forward shape without its
``_INV`` twin, an after-midnight trip, an empty departure time, a single-stop
trip, a stale route long name, and a route of a different nucleus that the
builder must ignore.
"""

import contextlib
import gzip
import importlib.util
import io
import json
import os
import pathlib
import tempfile
import unittest
import zipfile

BUILDER_PATH = pathlib.Path(__file__).with_name("build-rodalies-pack.py")


def _load_builder():
    """Import the builder by path: its file name holds a dash."""
    spec = importlib.util.spec_from_file_location("build_rodalies_pack", BUILDER_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


builder = _load_builder()

GENERATED_AT = "2026-11-01T00:00:00Z"

# The header names carry the feed's padding on purpose: the builder strips them.
BASE_MEMBERS = {
    "agency.txt": (
        "agency_name,agency_url,agency_timezone\n"
        "Renfe Cercanias,https://www.renfe.com,Europe/Madrid\n"
    ),
    "routes.txt": (
        "route_id,route_short_name,route_long_name,route_type,route_color,"
        "route_text_color                    \n"
        "51T0001R1  ,R1  ,Molins de Rei                    -Maçanet-Massanes              ,2,7DBCEC,FFFFFF\n"
        "51T0002R1  ,R1  ,Maçanet-Massanes                 -Molins de Rei                 ,2,7DBCEC,FFFFFF\n"
        "51T0003R2N ,R2N ,Aeroport                         -Sant Celoni                   ,2,146520,FFFFFF\n"
        "10T0001C1  ,C1  ,Zaragoza - Huesca                                                ,2,111111,FFFFFF\n"
    ),
    "stops.txt": (
        "stop_id,stop_name,stop_lat,stop_lon,wheelchair_boarding                \n"
        "101,Estació A,41.0,2.0,1\n"
        "102,Estació B,41.01,2.0,0\n"
        "103,Estació C,41.02,2.0,2\n"
        "104,Estació D,41.03,2.0,1\n"
        "201,Aeroport,41.5,2.1,1\n"
        "202,Sant Celoni,41.6,2.1,0\n"
        "301,Zaragoza Delicias,41.6586576,-0.9112693,1\n"
        "999,No serveix,41.9,2.9,0\n"
    ),
    "calendar.txt": (
        "service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,"
        "start_date,end_date                                                             \n"
        "WK,1,1,1,1,1,0,0,20261102,20261106\n"
        "WE,0,0,0,0,0,1,1,20261102,20261108\n"
    ),
    "calendar_dates.txt": "service_id,date,exception_type\nWK,20261104,2\n",
    "trips.txt": (
        "route_id,service_id,trip_id,trip_headsign,direction_id,shape_id,"
        "wheelchair_accessible\n"
        "51T0001R1,WK,t1,,,,51_R1,1\n"
        "51T0001R1,WK,t2,,,,51_R1,1\n"
        "51T0002R1,WE,t3,,,,51_R1_INV,1\n"
        "51T0003R2N,WK,t4,,,,51_R2N,1\n"
        "51T0003R2N,WE,t5,,,,51_R2N,1\n"
        "51T0001R1,WK,t6,,,,51_R1,1\n"
        "10T0001C1,WK,x1,,,,10_C1,1\n"
    ),
    "shapes.txt": (
        "shape_id,shape_pt_lat,shape_pt_lon,shape_pt_sequence\n"
        "51_R1,41.00,2.0,1\n"
        "51_R1,41.01,2.0,2\n"
        "51_R1,41.02,2.0,3\n"
        "51_R1,41.03,2.0,4\n"
        "51_R2N,41.5,2.1,1\n"
        "51_R2N,41.6,2.1,2\n"
        "10_C1,41.65,0.9,1\n"
        "10_C1,41.66,0.9,2\n"
    ),
    "stop_times.txt": (
        "trip_id,arrival_time,departure_time,stop_id,stop_sequence\n"
        "t1,06:00:00,06:00:00,101,1\n"
        "t1,06:10:00,06:10:30,102,2\n"
        "t1,06:20:00,06:20:00,103,3\n"
        "t1,06:30:00,06:30:00,104,4\n"
        "t2,24:10:00,24:10:00,101,1\n"
        "t2,24:20:00,,102,2\n"
        "t2,24:30:00,24:30:00,104,3\n"
        "t3,07:00:00,07:00:00,104,1\n"
        "t3,07:10:00,07:10:00,103,2\n"
        "t3,07:20:00,07:20:00,102,3\n"
        "t3,07:30:00,07:30:00,101,4\n"
        "t4,08:00:00,08:00:00,201,1\n"
        "t4,08:20:00,08:20:00,202,2\n"
        "t5,09:00:00,09:00:00,202,1\n"
        "t5,09:20:00,09:20:00,201,2\n"
        "t6,10:00:00,10:00:00,101,1\n"
        "x1,11:00:00,11:00:00,301,1\n"
    ),
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


EXPECTED_TOPOLOGY = {
    "v": 1,
    "generatedAt": GENERATED_AT,
    "timezone": "Europe/Madrid",
    "lines": [
        # The busiest route names the line; the padding and the dash are cleaned.
        {"code": "R1", "name": "Molins de Rei - Maçanet-Massanes", "colorHex": "7DBCEC", "textColorHex": "000000"},
        {"code": "R2N", "name": "Aeroport - Sant Celoni", "colorHex": "146520", "textColorHex": "FFFFFF"},
    ],
    "stations": [
        {"id": "101", "name": "Estació A", "lat": 41.0, "lon": 2.0, "lines": ["R1"], "wheelchair": 1},
        {"id": "102", "name": "Estació B", "lat": 41.01, "lon": 2.0, "lines": ["R1"], "wheelchair": 0},
        {"id": "103", "name": "Estació C", "lat": 41.02, "lon": 2.0, "lines": ["R1"], "wheelchair": 2},
        {"id": "104", "name": "Estació D", "lat": 41.03, "lon": 2.0, "lines": ["R1"], "wheelchair": 1},
        {"id": "201", "name": "Aeroport", "lat": 41.5, "lon": 2.1, "lines": ["R2N"], "wheelchair": 1},
        {"id": "202", "name": "Sant Celoni", "lat": 41.6, "lon": 2.1, "lines": ["R2N"], "wheelchair": 0},
    ],
    "directions": [
        {
            "line": "R1",
            "dir": 0,
            "stations": ["101", "102", "103", "104"],
            "points": [[41.0, 2.0], [41.01, 2.0], [41.02, 2.0], [41.03, 2.0]],
        },
        {
            "line": "R1",
            "dir": 1,
            # No 51_R1_INV in the fixture: the forward shape reversed.
            "stations": ["104", "103", "102", "101"],
            "points": [[41.03, 2.0], [41.02, 2.0], [41.01, 2.0], [41.0, 2.0]],
        },
        {
            "line": "R2N",
            "dir": 0,
            "stations": ["201", "202"],
            "points": [[41.5, 2.1], [41.6, 2.1]],
        },
        {
            "line": "R2N",
            "dir": 1,
            "stations": ["202", "201"],
            "points": [[41.6, 2.1], [41.5, 2.1]],
        },
    ],
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

    def build(self, *extra):
        """Run the builder on the fixture and return the decoded payloads."""
        code, stdout, stderr, files = self.run_builder(
            "--generated-at", GENERATED_AT, "--simplify-meters", "0", *extra, feed=make_feed()
        )
        self.assertEqual((code, stderr), (0, ""), stdout)
        topology = json.loads(files[builder.TOPOLOGY_FILE])
        schedule = json.loads(gzip.decompress(files[builder.SCHEDULE_FILE]))
        return topology, schedule, stdout, files

    # MARK: - Outputs

    def test_writes_the_topology_and_the_compressed_schedule(self):
        code, stdout, stderr, files = self.run_builder(
            "--generated-at", GENERATED_AT, "--simplify-meters", "0", feed=make_feed()
        )
        self.assertEqual((code, stderr), (0, ""))
        self.assertEqual(sorted(files), sorted([builder.TOPOLOGY_FILE, builder.SCHEDULE_FILE]))
        self.assertTrue(files[builder.SCHEDULE_FILE].startswith(b"\x1f\x8b"))
        # The report names the feed, the lines and both sizes.
        self.assertIn("feed 20261102..20261108", stdout)
        self.assertIn("2 lines", stdout)
        self.assertIn("6 stations", stdout)
        self.assertIn("topology: %d bytes" % len(files[builder.TOPOLOGY_FILE]), stdout)
        self.assertIn("schedule: %d bytes gzip" % len(files[builder.SCHEDULE_FILE]), stdout)

    def test_topology_matches_the_expected_payload(self):
        topology, _, _, files = self.build()
        self.assertEqual(topology, EXPECTED_TOPOLOGY)
        text = json.dumps(topology, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
        self.assertEqual(files[builder.TOPOLOGY_FILE], (text + "\n").encode("utf-8"))

    def test_non_nucleus_routes_are_ignored(self):
        topology, schedule, _, _ = self.build()
        self.assertEqual([line["code"] for line in topology["lines"]], ["R1", "R2N"])
        self.assertNotIn("301", [station["id"] for station in topology["stations"]])
        self.assertNotIn("x1", schedule["trips"])

    def test_schedule_dates_follow_the_calendar_and_its_exception(self):
        _, schedule, _, _ = self.build()
        # WK every weekday but the 4th (removed by calendar_dates), WE the weekend.
        self.assertEqual(
            schedule["dates"], ["20261102", "20261103", "20261105", "20261106", "20261107", "20261108"]
        )
        self.assertEqual(schedule["lines"], ["R1", "R2N"])
        self.assertEqual(schedule["timezone"], "Europe/Madrid")

    def test_schedule_departures_resolve_to_real_values(self):
        _, schedule, _, _ = self.build()

        def resolve(date, station):
            flat = schedule["days"][date][station]
            rows = [flat[index:index + 5] for index in range(0, len(flat), 5)]
            return [
                (
                    schedule["lines"][line],
                    direction,
                    seconds,
                    schedule["headsigns"][headsign],
                    schedule["trips"][trip],
                )
                for line, direction, seconds, headsign, trip in rows
            ]

        self.assertEqual(
            resolve("20261102", "101"),
            [
                # t1 leaves A at 06:00 towards the last stop, Estació D.
                ("R1", 0, 21600, "Estació D", "t1"),
                # t2 leaves after midnight: the service-day time passes 86400.
                ("R1", 0, 87000, "Estació D", "t2"),
            ],
        )
        # The intermediate stop with no departure time uses its arrival (24:20).
        self.assertIn(("R1", 0, 87600, "Estació D", "t2"), resolve("20261102", "102"))
        # The last stop of a trip is not a departure, and the single-stop trip
        # has none either: 103 and 104 only see the forward morning run.
        self.assertEqual(resolve("20261102", "103"), [("R1", 0, 22800, "Estació D", "t1")])
        self.assertNotIn("104", schedule["days"]["20261102"])
        self.assertEqual(resolve("20261102", "201"), [("R2N", 0, 28800, "Sant Celoni", "t4")])
        # The weekend service is the reverse direction of both lines.
        self.assertEqual(resolve("20261107", "103"), [("R1", 1, 25800, "Estació A", "t3")])
        self.assertEqual(resolve("20261107", "202"), [("R2N", 1, 32400, "Aeroport", "t5")])
        # The removed weekday has no day at all.
        self.assertNotIn("20261104", schedule["days"])

    def test_output_is_deterministic(self):
        first = self.run_builder("--generated-at", GENERATED_AT, feed=make_feed())[3]
        second = self.run_builder("--generated-at", GENERATED_AT, feed=make_feed())[3]
        self.assertEqual(first, second)

    # MARK: - Arguments and failures

    def test_simplification_keeps_the_endpoints(self):
        topology, _, _, _ = self.build("--simplify-meters", "10000")
        points = topology["directions"][0]["points"]
        self.assertEqual(points, [[41.0, 2.0], [41.03, 2.0]])

    def test_missing_member_fails(self):
        code, _, stderr, _ = self.run_builder(feed=make_feed(drop=["stop_times.txt"]))
        self.assertEqual(code, 1)
        self.assertIn("missing member in the GTFS archive: stop_times.txt", stderr)

    def test_feed_without_the_nucleus_fails(self):
        members = {
            "routes.txt": (
                "route_id,route_short_name,route_long_name,route_type\n"
                "10T0001C1,C1,Zaragoza - Huesca,2\n"
            )
        }
        code, _, stderr, _ = self.run_builder(feed=make_feed(members=members))
        self.assertEqual(code, 1)
        self.assertIn("no route with the Catalonia nucleus prefix 51T", stderr)

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
