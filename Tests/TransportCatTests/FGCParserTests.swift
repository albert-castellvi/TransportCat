import XCTest
@testable import TransportCat

/// Decoding tests for the FGC open-data payloads (specs S1-S4). Every fixture
/// is a real capture, so the tests pin the live shapes (all-string values,
/// GeoJSON shapes, paged stops) instead of a hand-written schema.
final class FGCParserTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        #if os(Linux)
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") else {
            XCTFail("Missing fixture \(name).json")
            throw FGCError.unexpectedPayload("missing fixture \(name)")
        }
        return try Data(contentsOf: url)
        #else
        guard let url = Bundle(for: FGCParserTests.self).url(forResource: name, withExtension: "json") else {
            XCTFail("Missing fixture \(name).json")
            throw FGCError.unexpectedPayload("missing fixture \(name)")
        }
        return try Data(contentsOf: url)
        #endif
    }

    /// `codigo-estaciones` is paged at 100 rows; the two captured pages make
    /// the 110-row live dataset.
    private func allStations() throws -> [FGCStation] {
        try FGCParser.stations(from: fixture("fgc-stations"))
            + FGCParser.stations(from: fixture("fgc-stations-page2"))
    }

    private func allStops() throws -> [FGCStop] {
        try (1...4).flatMap { try FGCParser.stops(from: fixture("fgc-stops-page\($0)")) }
    }

    // MARK: - S1 / S2: routes

    func testRoutesParseColorAndNonEmptyPolylines() throws {
        let routes = try FGCParser.routes(from: fixture("fgc-routes"))
        let colors = try FGCParser.textColors(from: fixture("fgc-line-colors"))
        let lines = FGCNetwork.merge(routes: routes, textColors: colors)

        XCTAssertEqual(lines.count, 22)
        let s8 = try XCTUnwrap(lines.first { $0.code == "S8" })
        XCTAssertEqual(s8.colorHex, "49C0DE")
        XCTAssertEqual(s8.textColorHex, "FFFFFF")
        XCTAssertFalse(s8.polylines.isEmpty)
        XCTAssertTrue(s8.polylines.allSatisfy { $0.count >= 2 })
        // `shape` is a GeoJSON MultiLineString of [lon, lat] pairs.
        XCTAssertEqual(s8.polylines[0][0].longitude, 2.1484709, accuracy: 1e-7)
        XCTAssertEqual(s8.polylines[0][0].latitude, 41.3745221, accuracy: 1e-7)

        // The colour file is the source of the text colour, not the routes.
        let s3 = try XCTUnwrap(lines.first { $0.code == "S3" })
        XCTAssertEqual(s3.colorHex, "4F868E")
        XCTAssertEqual(s3.textColorHex, "FFFFFF")
    }

    func testRouteWithoutShapeKeepsNoPolyline() throws {
        let lines = FGCNetwork.merge(
            routes: try FGCParser.routes(from: fixture("fgc-routes")),
            textColors: try FGCParser.textColors(from: fixture("fgc-line-colors"))
        )
        let l1 = try XCTUnwrap(lines.first { $0.code == "L1" })
        XCTAssertEqual(l1.colorHex, "000000")
        XCTAssertTrue(l1.polylines.isEmpty)
    }

    /// A route colour is conventionally uppercase so the map can compare and
    /// parse hex without caring about the live lower/upper mix.
    func testRouteColorsAreNormalizedToUppercase() throws {
        let lines = try FGCParser.routes(from: fixture("fgc-routes"))
        let r50 = try XCTUnwrap(lines.first { $0.code == "R50" })
        XCTAssertEqual(r50.colorHex, "00738A")
        XCTAssertTrue(lines.allSatisfy { $0.colorHex == $0.colorHex.uppercased() })
    }

    /// An empty `route_short_name` is as absent as a null one: the record must
    /// fall back to `route_id` instead of being dropped, and only a route with
    /// both values empty disappears.
    func testEmptyRouteShortNameFallsBackToRouteID() {
        let lines = FGCParser.routes(fromRecords: [
            ["route_id": "X", "route_short_name": "", "route_long_name": "Xarxa"],
            ["route_id": "Y", "route_short_name": "S1"],
            ["route_id": "", "route_short_name": ""],
        ])
        XCTAssertEqual(lines.map(\.code), ["X", "S1"])
        XCTAssertEqual(lines.first?.name, "Xarxa")
        // A filled short name still wins over the route id.
        XCTAssertEqual(lines.last?.name, "S1")
    }

    // MARK: - S2: stations and the stop-code join

    func testStationsParseOrderedWithCodeAndName() throws {
        let stations = try allStations()
        XCTAssertEqual(stations.count, 110)
        let gracia = try XCTUnwrap(stations.first { $0.code == "GR" })
        XCTAssertEqual(gracia.name, "Gràcia")
        XCTAssertEqual(gracia.networkLine, 1)
        XCTAssertEqual(gracia.order, 3)
        // The station row itself has no coordinates: they are joined from the
        // stop catalog by code.
        XCTAssertNil(gracia.point)
    }

    func testStopCodeJoinUsesStopIDEqualityOrPrefix() throws {
        let stops = try allStops()
        XCTAssertEqual(stops.count, 305)

        let point = try XCTUnwrap(FGCNetwork.stopPoint(for: "GR", in: stops))
        XCTAssertEqual(point.latitude, 41.39909823, accuracy: 1e-8)
        XCTAssertEqual(point.longitude, 2.152662325, accuracy: 1e-8)
        // Prefixed platform rows ("GR1"...) share the coordinates of "GR".
        let platform = try XCTUnwrap(FGCNetwork.stopPoint(for: "GR1", in: stops))
        XCTAssertEqual(platform, point)
        XCTAssertNil(FGCNetwork.stopPoint(for: "ZZ", in: stops))
    }

    func testStationJoinAttachesCoordinatesToStations() throws {
        let stations = FGCNetwork.stations(
            try allStations(),
            points: FGCNetwork.stopIndex(try allStops())
        )
        let gracia = try XCTUnwrap(stations.first { $0.code == "GR" })
        XCTAssertEqual(gracia.point?.latitude ?? 0, 41.39909823, accuracy: 1e-8)
        // A station with no stop row keeps no point instead of inventing one.
        let unmatched = try XCTUnwrap(stations.first { $0.code == "Y7" })
        XCTAssertNil(unmatched.point)
    }

    // MARK: - S3: live trains

    func testPositionsParseEveryLiveTrainWithAGeoPoint() throws {
        let stationNames = FGCNetwork.stationNames(from: try allStations())
        let trains = try FGCParser.trains(from: fixture("fgc-positions"), stationNames: stationNames)
        let raw = JSONValue.dictionary(from: try JSONSerialization.jsonObject(with: fixture("fgc-positions")))
        let results = try XCTUnwrap(JSONValue.array(from: raw?["results"]))

        XCTAssertEqual(trains.count, results.count)
        XCTAssertEqual(trains.count, 64)
        XCTAssertTrue(trains.allSatisfy { $0.position.latitude != 0 && $0.position.longitude != 0 })
    }

    func testTrainFieldsDecodeFromLiveRecord() throws {
        let stationNames = FGCNetwork.stationNames(from: try allStations())
        let trains = try FGCParser.trains(from: fixture("fgc-positions"), stationNames: stationNames)
        let train = try XCTUnwrap(trains.first { $0.id == "6c4bdae302747640fd55c10d40|6a2dc6eb00" })

        XCTAssertEqual(train.lineCode, "S1")
        XCTAssertEqual(train.direction, "D")
        XCTAssertEqual(train.originCode, "NA")
        XCTAssertEqual(train.destinationCode, "PC")
        XCTAssertEqual(train.destinationName, "Pl. Catalunya")
        XCTAssertEqual(train.nextStopCodes, ["PR", "PC"])
        XCTAssertTrue(train.isOnTime)
        XCTAssertEqual(train.stoppedAtStopCode, "GR")
        XCTAssertEqual(train.unitType, "115")
        XCTAssertTrue(train.occupancy.isEmpty)
        XCTAssertEqual(train.position.latitude, 41.39866286895463, accuracy: 1e-9)
        XCTAssertEqual(train.position.longitude, 2.153035378144044, accuracy: 1e-9)
    }

    func testPerCarOccupancyDecodes() throws {
        let trains = try FGCParser.trains(from: fixture("fgc-positions"))
        let train = try XCTUnwrap(trains.first { $0.id == "6c4bdae302747640fd55c10d40|6a2dc6e405" })
        XCTAssertEqual(train.occupancy.map(\.car), ["mi", "ri", "m1", "m2"])
        XCTAssertEqual(train.occupancy.map(\.percent), [46, 45, 47, 24])
    }

    func testDelayedTrainDecodes() throws {
        let trains = try FGCParser.trains(from: fixture("fgc-positions"))
        let train = try XCTUnwrap(trains.first { $0.id == "625cdae3027432|632dc7e605" })
        XCTAssertFalse(train.isOnTime)
        XCTAssertEqual(train.lineCode, "S8")
        XCTAssertEqual(train.nextStopCodes, ["ME"])
        XCTAssertNil(train.stoppedAtStopCode)
    }

    /// `"NO"` is both the feed's "not stopped" sentinel and a real station
    /// code of the catalog (it sits between `CT` and `PN` on S2), so it only
    /// reads as the sentinel when no station of the network uses that code.
    func testStoppedAtNOSentinelDoesNotHideTheRealStation() throws {
        let stationNames = FGCNetwork.stationNames(from: try allStations())
        XCTAssertNotNil(stationNames["NO"], "The captured catalog really codes a station as NO")
        let record: [String: Any] = [
            "id": "t-no",
            "lin": "S2",
            "geo_point_2d": ["lon": 2.0902, "lat": 41.5708],
            "dir": "D",
            "origen": "PN",
            "desti": "PC",
            "properes_parades": #"{"parada": "CT"}"#,
            "estacionat_a": "NO",
            "en_hora": "True",
        ]

        let withCatalog = try XCTUnwrap(
            FGCParser.trains(fromRecords: [record], stationNames: stationNames).first
        )
        XCTAssertEqual(withCatalog.stoppedAtStopCode, "NO")

        // Without a catalog that knows `NO`, it stays the not-stopped sentinel.
        let withoutCatalog = try XCTUnwrap(FGCParser.trains(fromRecords: [record]).first)
        XCTAssertNil(withoutCatalog.stoppedAtStopCode)
    }

    func testMalformedRecordIsSkippedNotFatal() throws {
        let json = """
        {"total_count":3,"results":[
          {"id":"valid-a","lin":"S1","geo_point_2d":{"lon":2.15,"lat":41.39},"dir":"A","origen":"PC",
           "desti":"NA","properes_parades":"{\\"parada\\": \\"NA\\"}","estacionat_a":null,
           "en_hora":"True","tipus_unitat":"112","ocupacio_mi_percent":"5"},
          {"id":"no-geo","lin":"S1","dir":"A","origen":"PC","desti":"NA",
           "properes_parades":"{\\"parada\\": \\"NA\\"}","en_hora":"True"},
          {"id":"valid-b","lin":"S1","geo_point_2d":{"lon":2.15,"lat":41.39},"dir":"A","origen":"PC",
           "desti":"NA","properes_parades":"","estacionat_a":"NO","en_hora":"False"}
        ]}
        """.data(using: .utf8)!
        let trains = try FGCParser.trains(from: json)
        XCTAssertEqual(trains.map(\.id), ["valid-a", "valid-b"])
        XCTAssertFalse(trains[1].isOnTime)
        XCTAssertNil(trains[1].stoppedAtStopCode)
        XCTAssertEqual(trains[0].occupancy.map(\.percent), [5])
    }

    /// `properes_parades` is a string of concatenated JSON objects, not JSON:
    /// splitting on `;` and decoding each chunk must keep order and ignore a
    /// malformed chunk.
    func testProperesParadesParsesOrderedCodesAndIgnoresGarbage() {
        XCTAssertEqual(
            FGCNetwork.nextStopCodes(from: #"{"parada": "GR"};{"parada": "PR"}"#),
            ["GR", "PR"]
        )
        XCTAssertEqual(
            FGCNetwork.nextStopCodes(from: #"{"parada":"A"}; junk ;{"parada":"B"};{"parada":""}"#),
            ["A", "B"]
        )
        XCTAssertEqual(FGCNetwork.nextStopCodes(from: nil), [])
        XCTAssertEqual(FGCNetwork.nextStopCodes(from: ""), [])
    }

    func testMalformedPayloadThrows() {
        XCTAssertThrowsError(try FGCParser.routes(from: Data("{}".utf8)))
        XCTAssertThrowsError(try FGCParser.stops(from: Data("{}".utf8)))
        XCTAssertThrowsError(try FGCParser.stations(from: Data("{}".utf8)))
        XCTAssertThrowsError(try FGCParser.trains(from: Data("{}".utf8)))
    }
}
