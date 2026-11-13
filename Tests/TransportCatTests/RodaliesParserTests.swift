import XCTest
@testable import TransportCat

/// Decoding tests for the Rodalies data (Renfe's GTFS-Realtime JSON feeds, the
/// bundled topology and the published timetable pack).
///
/// The realtime fixtures are trimmed real captures, so the tests pin the live
/// shapes (all-string timestamps, missing positions, skipped stops) instead of a
/// hand-written schema. The topology and the pack come from the same tiny GTFS
/// feed, which is what makes the trip-id join assertable.
final class RodaliesParserTests: XCTestCase {
    /// The lines of the topology fixture, the nucleus filter of every poll.
    private let fixtureLines = ["R1", "R16"]

    private func fixture(_ name: String, extension ext: String = "json") throws -> Data {
        #if os(Linux)
        guard let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures") else {
            XCTFail("Missing fixture \(name).\(ext)")
            throw RodaliesError.unexpectedPayload("missing fixture \(name)")
        }
        return try Data(contentsOf: url)
        #else
        guard let url = Bundle(for: RodaliesParserTests.self).url(forResource: name, withExtension: ext) else {
            XCTFail("Missing fixture \(name).\(ext)")
            throw RodaliesError.unexpectedPayload("missing fixture \(name)")
        }
        return try Data(contentsOf: url)
        #endif
    }

    /// The pack fixture travels as base64 inside a JSON file: the test bundle
    /// would not carry a raw `.gz` as a resource. Decoding it is part of the
    /// test, so the gzip reader is exercised on real pack bytes.
    private func schedule() throws -> RodaliesSchedule {
        let wrapper = try JSONSerialization.jsonObject(with: try fixture("rodalies-schedule")) as? [String: Any]
        let base64 = try XCTUnwrap(wrapper?["gzipBase64"] as? String)
        let data = try XCTUnwrap(Data(base64Encoded: base64))
        return try XCTUnwrap(RodaliesClient.decodeSchedule(data), "the schedule fixture must decode")
    }

    private func topology() throws -> RodaliesTopology {
        let data = try fixture("rodalies-topology")
        return try XCTUnwrap(RodaliesTopology.decode(data), "the topology fixture must decode")
    }

    // MARK: - Trip id

    /// Renfe codes the trip id as service + train + line: the line is the
    /// suffix, and the longest known code wins (`R2N` before `R2`).
    func testLineCodeIsTheTripIDSuffix() {
        XCTAssertEqual(RodaliesParser.lineCode(fromTripID: "5116V18122R16", knownLines: ["R1", "R16"]), "R16")
        XCTAssertEqual(RodaliesParser.lineCode(fromTripID: "5116V18122R16", knownLines: ["R16", "R1"]), "R16")
        XCTAssertEqual(RodaliesParser.lineCode(fromTripID: "5115J15000R2N", knownLines: ["R2", "R2N"]), "R2N")
        XCTAssertEqual(RodaliesParser.lineCode(fromTripID: "5115J15000R2", knownLines: ["R2", "R2N"]), "R2")
        XCTAssertEqual(RodaliesParser.lineCode(fromTripID: "5115J15000R11", knownLines: ["R1", "R11"]), "R11")
        // A suffix with no service/train prefix is not a line.
        XCTAssertNil(RodaliesParser.lineCode(fromTripID: "R16", knownLines: ["R16"]))
        // A line that is not in the nucleus is not a match either.
        XCTAssertNil(RodaliesParser.lineCode(fromTripID: "5116V18122R16", knownLines: ["R1", "R2"]))
        XCTAssertNil(RodaliesParser.lineCode(fromTripID: "", knownLines: ["R1"]))
    }

    func testTrainNumberIsReadFromTheTripID() {
        XCTAssertEqual(
            RodaliesParser.trainNumber(fromTripID: "5116V18122R16", lineCode: "R16"),
            "18122"
        )
        XCTAssertEqual(
            RodaliesParser.trainNumber(fromTripID: "5115J15000R15", lineCode: "R15"),
            "15000"
        )
        XCTAssertNil(RodaliesParser.trainNumber(fromTripID: "5115J15000R15", lineCode: "R1"))
    }

    // MARK: - Vehicle positions

    /// Only the nucleus trips with a GPS fix survive: a different nucleus, a
    /// train of another network and an entity without `position` are dropped.
    func testVehiclesKeepTheNucleusAndSkipMissingFixes() throws {
        let vehicles = RodaliesParser.vehicles(
            from: try fixture("rodalies-vehicles"),
            knownLines: fixtureLines
        )
        XCTAssertEqual(vehicles.map(\.vehicleID), ["18122", "18123", "25731", "25613"])
        XCTAssertEqual(vehicles.map(\.lineCode), ["R16", "R16", "R1", "R1"])

        let first = try XCTUnwrap(vehicles.first)
        XCTAssertEqual(first.tripID, "5116V18122R16")
        XCTAssertEqual(first.position.latitude, 41.11129, accuracy: 1e-7)
        XCTAssertEqual(first.position.longitude, 1.2534051, accuracy: 1e-7)
        XCTAssertEqual(first.stopID, "71500")
        XCTAssertEqual(first.status, "INCOMING_AT")
        XCTAssertEqual(first.timestamp, Date(timeIntervalSince1970: 1_794_560_334))
        XCTAssertNil(first.bearingDegrees)
    }

    /// The `label` sometimes carries the platform; it is kept but never parsed
    /// as a position.
    func testVehicleLabelWithPlatformIsTolerated() throws {
        let vehicles = RodaliesParser.vehicles(
            from: try fixture("rodalies-vehicles"),
            knownLines: fixtureLines
        )
        let labelled = try XCTUnwrap(vehicles.first { $0.vehicleID == "25613" })
        XCTAssertEqual(labelled.label, "R1-25613-PLATF.(2)")
    }

    /// A payload that is not a GTFS-Realtime envelope is empty, not fatal.
    func testMalformedVehiclePayloadIsEmpty() {
        XCTAssertTrue(RodaliesParser.vehicles(from: Data("not json".utf8), knownLines: fixtureLines).isEmpty)
        XCTAssertTrue(
            RodaliesParser.vehicles(from: Data("{\"entity\":[]}".utf8), knownLines: fixtureLines).isEmpty
        )
    }

    // MARK: - Trip updates

    /// Delays are seconds, may be negative (a train ahead of time), and fall
    /// back to the first stop that reports one.
    func testTripDelaysKeepTheSignAndFallBackToStops() throws {
        let delays = RodaliesParser.tripDelays(
            from: try fixture("rodalies-trip-updates"),
            knownLines: fixtureLines
        )
        XCTAssertEqual(delays["5116V18122R16"], 0)
        XCTAssertEqual(delays["5116V18123R16"], 1800)
        XCTAssertEqual(delays["5116V25613R1"], 3240)
        // Hand-built entity: the delay only exists per stop.
        XCTAssertEqual(delays["5115J10003R1"], -60)
        // Other networks and other nuclei lines are filtered out.
        XCTAssertNil(delays["5116V77416R4"])
        XCTAssertNil(delays["3016V35713C5"])
    }

    // MARK: - Join

    /// The trip id gives the line; the timetable gives the direction and the
    /// destination; the trip updates give the delay.
    func testTrainsJoinLineDirectionHeadsignAndDelay() throws {
        let delays = RodaliesParser.tripDelays(
            from: try fixture("rodalies-trip-updates"),
            knownLines: fixtureLines
        )
        let trains = RodaliesParser.trains(
            from: RodaliesParser.vehicles(from: try fixture("rodalies-vehicles"), knownLines: fixtureLines),
            delays: delays,
            tripIndex: try schedule().tripIndex()
        )
        XCTAssertEqual(trains.count, 4)

        let morning = try XCTUnwrap(trains.first { $0.id == "18122" })
        XCTAssertEqual(morning.lineCode, "R16")
        XCTAssertEqual(morning.direction, 0)
        XCTAssertEqual(morning.headsign, "Vilanova i la Geltrú")
        XCTAssertEqual(morning.delaySeconds, 0)
        // INCOMING_AT: the stop it reports is the next one, not the current.
        XCTAssertNil(morning.currentStopID)
        XCTAssertEqual(morning.nextStopID, "71500")

        let stopped = try XCTUnwrap(trains.first { $0.id == "18123" })
        XCTAssertEqual(stopped.direction, 1)
        XCTAssertEqual(stopped.headsign, "Barcelona-Sants")
        XCTAssertEqual(stopped.delaySeconds, 1800)
        XCTAssertEqual(stopped.currentStopID, "65405")
        XCTAssertNil(stopped.nextStopID)

        let forward = try XCTUnwrap(trains.first { $0.id == "25731" })
        XCTAssertEqual(forward.lineCode, "R1")
        XCTAssertEqual(forward.direction, 0)
        XCTAssertEqual(forward.headsign, "Barcelona-Passeig de Gràcia")

        let reverse = try XCTUnwrap(trains.first { $0.id == "25613" })
        XCTAssertEqual(reverse.direction, 1)
        XCTAssertEqual(reverse.headsign, "L'Hospitalet de Llobregat")
        XCTAssertEqual(reverse.delaySeconds, 3240)
    }

    /// A trip the timetable does not know (a stale pack) still becomes a train
    /// on its line: no direction, no destination, no crash.
    func testUnknownTripKeepsItsLineWithoutDirection() {
        let position = RodaliesVehiclePosition(
            tripID: "5116V99999R1",
            lineCode: "R1",
            vehicleID: "99999",
            label: nil,
            position: GeoPoint(latitude: 41.38, longitude: 2.14),
            bearingDegrees: 90,
            timestamp: nil,
            stopID: nil,
            status: nil
        )
        let trains = RodaliesParser.trains(from: [position], delays: [:], tripIndex: [:])
        let train = trains.first
        XCTAssertEqual(trains.count, 1)
        XCTAssertEqual(train?.lineCode, "R1")
        XCTAssertNil(train?.direction)
        XCTAssertNil(train?.headsign)
        XCTAssertEqual(train?.bearingDegrees, 90)
    }

    // MARK: - Timetable pack

    func testSchedulePackDecodesFromGzip() throws {
        let pack = try schedule()
        XCTAssertEqual(pack.timezone, "Europe/Madrid")
        XCTAssertEqual(pack.dates, ["20261112", "20261113"])
        XCTAssertEqual(pack.lineCodes, ["R1", "R16"])
        XCTAssertEqual(pack.days["20261113"]?["71801"]?.count, 3 * RodaliesSchedule.rowWidth)

        let rows = pack.rows(stationID: "71801", date: "20261113")
        XCTAssertEqual(rows.map(\.tripID), ["5116V25731R1", "5116V25613R1", "5116V18122R16"])
        XCTAssertEqual(rows.map(\.seconds), [22200, 25800, 87000])
        XCTAssertEqual(rows.map(\.headsign), [
            "Barcelona-Passeig de Gràcia",
            "L'Hospitalet de Llobregat",
            "Vilanova i la Geltrú",
        ])
        // A station the day does not serve is empty, not fatal.
        XCTAssertTrue(pack.rows(stationID: "00000", date: "20261113").isEmpty)
        XCTAssertTrue(pack.rows(stationID: "71801", date: "19990101").isEmpty)
    }

    func testSchedulePackRejectsBytesThatAreNotAGzipPack() throws {
        XCTAssertNil(RodaliesClient.decodeSchedule(Data("{}".utf8)))
        XCTAssertNil(RodaliesClient.decodeSchedule(Data()))
        // A valid gzip of something else (the topology) must not decode as a pack.
        XCTAssertNil(RodaliesClient.decodeSchedule(try fixture("rodalies-topology")))
    }

    // MARK: - Topology

    func testTopologyFixtureLookups() throws {
        let topology = try topology()
        XCTAssertEqual(topology.lines.map(\.code), ["R1", "R16"])
        XCTAssertEqual(topology.line(code: "R1")?.name, "L'Hospitalet de Llobregat - Maçanet-Massanes")
        XCTAssertEqual(topology.line(code: "R1")?.colorHex, "7DBCEC")
        // A light colour ships a dark text colour, and vice versa.
        XCTAssertEqual(topology.line(code: "R1")?.textColorHex, "000000")
        XCTAssertEqual(topology.line(code: "R16")?.textColorHex, "FFFFFF")

        let sants = try XCTUnwrap(topology.station(id: "71801"))
        XCTAssertEqual(sants.name, "Barcelona-Sants")
        XCTAssertEqual(sants.lineCodes, ["R1", "R16"])
        XCTAssertEqual(sants.wheelchairBoarding, 1)
        XCTAssertEqual(sants.isAccessible, true)
        XCTAssertEqual(sants.point.latitude, 41.379, accuracy: 1e-7)

        XCTAssertEqual(topology.lines(at: "71801").map(\.code), ["R1", "R16"])
        XCTAssertEqual(topology.stations(ofLine: "R1").map(\.id), ["72305", "71801", "71802"])
        XCTAssertNil(topology.line(code: "R99"))
        XCTAssertNil(topology.station(id: "00000"))
        XCTAssertNil(topology.direction(line: "R99", direction: 0))
    }

    func testTopologyDirectionsCarryOrderedStationsAndTrack() throws {
        let topology = try topology()
        let forward = try XCTUnwrap(topology.direction(line: "R1", direction: 0))
        XCTAssertEqual(forward.stationIDs, ["72305", "71801", "71802"])
        XCTAssertEqual(forward.points.count, 3)
        XCTAssertEqual(try XCTUnwrap(forward.points.first).latitude, 41.364, accuracy: 1e-7)

        // The fixture feed has no `_INV` shape: the reverse direction is the
        // forward track reversed, with the stations in travel order.
        let reverse = try XCTUnwrap(topology.direction(line: "R1", direction: 1))
        XCTAssertEqual(reverse.stationIDs, ["71802", "71801", "72305"])
        XCTAssertEqual(reverse.points, Array(forward.points.reversed()))
    }

    func testTopologyRejectsAnUnknownVersion() throws {
        var payload = try JSONSerialization.jsonObject(with: try fixture("rodalies-topology")) as? [String: Any]
        payload?["v"] = 99
        let data = try JSONSerialization.data(withJSONObject: try XCTUnwrap(payload))
        XCTAssertNil(RodaliesTopology.decode(data))
    }

    /// The committed topology is what the app bundles: it must still carry the
    /// whole nucleus, otherwise the map would draw a partial network.
    func testBundledTopologyCoversTheNucleus() throws {
        let bundled = try XCTUnwrap(RodaliesTopology.bundled, "rodalies-topology.json must ship in the bundle")
        XCTAssertEqual(bundled.lines.count, 19)
        let codes = Set(bundled.lines.map(\.code))
        for code in ["R1", "R2", "R2N", "R2S", "R3", "R4", "R7", "R8", "RG1", "RT1", "RT2", "RL4"] {
            XCTAssertTrue(codes.contains(code), "missing line \(code)")
        }
        XCTAssertGreaterThanOrEqual(bundled.stations.count, 200)
        XCTAssertTrue(bundled.stations.allSatisfy { !$0.lineCodes.isEmpty })
        for line in bundled.lines {
            for direction in 0...1 {
                let geometry = try XCTUnwrap(
                    bundled.direction(line: line.code, direction: direction),
                    "\(line.code) direction \(direction)"
                )
                XCTAssertGreaterThanOrEqual(geometry.points.count, 2)
                XCTAssertGreaterThanOrEqual(geometry.stationIDs.count, 2)
            }
        }
    }
}
