import XCTest
@testable import TransportCat

/// Parsing of the metro station accesses (spec S17) and of the FGC station
/// accessibility state written into `FGCParsers`.
///
/// Written before the implementation. The access payload shape follows the
/// documented `LlistaAccessos` GeoJSON (`DOC-TMB/transit.json`, endpoint
/// `/transit/estacions/{codi_grup_estacio}/accessos`, definition `Acces`).
final class AccessParserTests: XCTestCase {
    /// Reads a fixture from the repository, so the test does not depend on how
    /// Xcode copies the folder into the test bundle (and works through the
    /// harness symlinks).
    private func fixture(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name + ".json")
        return try Data(contentsOf: url)
    }

    // MARK: - Access parsing

    func testAccessesParseNameCodeAndAccessibilityType() throws {
        let accesses = try TMBAccessParser.accesses(from: fixture("accessos-bellvitge"))

        XCTAssertEqual(accesses.count, 3)
        XCTAssertEqual(accesses.map(\.name), ["Rambla de Bellvitge", "Gran Via Nord", "Canal"])
        XCTAssertEqual(accesses.map(\.code), [11101, 11102, 11103])
        XCTAssertEqual(accesses.map(\.kind), [.accessible, .notAccessible, .partiallyAccessible])
    }

    func testCatalanLabelsPerAccessibilityType() {
        XCTAssertEqual(TMBAccessKind.accessible.label, "Accessible")
        XCTAssertEqual(TMBAccessKind.partiallyAccessible.label, "Parcialment accessible")
        XCTAssertEqual(TMBAccessKind.notAccessible.label, "No accessible")
        XCTAssertEqual(TMBAccessKind.unknown.label, "Sense informació")
    }

    func testAccessibilityTypeFoldsCaseAndDiacritics() {
        XCTAssertEqual(TMBAccessKind(accessibilityText: "No Accessible"), .notAccessible)
        XCTAssertEqual(TMBAccessKind(accessibilityText: "accés accessible"), .unknown)
        XCTAssertEqual(TMBAccessKind(accessibilityText: "Accessibilitat parcial"), .partiallyAccessible)
        XCTAssertEqual(TMBAccessKind(accessibilityText: nil), .unknown)
        XCTAssertEqual(TMBAccessKind(accessibilityText: ""), .unknown)
    }

    func testMissingOrUnknownAccessibilityTypeReadsAsUnknown() throws {
        let json = """
        {"type":"FeatureCollection","features":[\
        {"type":"Feature","properties":{"CODI_ACCES":7,"NOM_ACCES":"Nord","NOM_TIPUS_ACCESSIBILITAT":"En obres"}},\
        {"type":"Feature","properties":{"NOM_ACCES":"Est"}}]}
        """
        let accesses = try TMBAccessParser.accesses(from: Data(json.utf8))
        XCTAssertEqual(accesses.count, 2)
        XCTAssertEqual(accesses[0].kind, .unknown)
        XCTAssertEqual(accesses[0].code, 7)
        XCTAssertEqual(accesses[1].kind, .unknown)
        XCTAssertNil(accesses[1].code)
    }

    func testPayloadWithoutFeaturesThrows() {
        XCTAssertThrowsError(try TMBAccessParser.accesses(from: Data("{}".utf8)))
        XCTAssertThrowsError(try TMBAccessParser.accesses(from: Data("[]".utf8)))
        XCTAssertThrowsError(try TMBAccessParser.accesses(from: Data("not json".utf8)))
    }

    func testEmptyFeatureCollectionParsesAsNoAccesses() throws {
        let accesses = try TMBAccessParser.accesses(from: Data(#"{"features":[]}"#.utf8))
        XCTAssertTrue(accesses.isEmpty)
    }

    // MARK: - Group station code

    /// The documented `LlistaAccessos` endpoint is keyed by `CODI_GRUP_ESTACIO`
    /// while the app knows `CODI_ESTACIO`; the real L1 station feed pins the
    /// offset for every station it contains.
    func testGroupStationCodeMatchesTheRealStationFeed() throws {
        let data = try fixture("stations-L1")
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let features = try XCTUnwrap(JSONValue.array(from: root?["features"]))
        var checked = 0
        for element in features {
            guard let properties = JSONValue.dictionary(from: JSONValue.dictionary(from: element)?["properties"]),
                  let stationCode = JSONValue.int(from: properties["CODI_ESTACIO"]),
                  let groupCode = JSONValue.int(from: properties["CODI_GRUP_ESTACIO"]) else { continue }
            XCTAssertEqual(TMBAccessParser.groupStationCode(forStationCode: stationCode), groupCode)
            checked += 1
        }
        XCTAssertGreaterThanOrEqual(checked, 3)
    }

    func testGroupStationCodeOffset() {
        // Documentation examples: station 210 → group 6660210, Palau Reial
        // (315) → 6660315.
        XCTAssertEqual(TMBAccessParser.groupStationCode(forStationCode: 210), 6660210)
        XCTAssertEqual(TMBAccessParser.groupStationCode(forStationCode: 315), 6660315)
    }

    // MARK: - FGC wheelchair_boarding (spec S17)

    func testFGCStopsCarryWheelchairBoarding() throws {
        let stops = try FGCParser.stops(from: fixture("fgc-stops-page1"))
        let plaçaCatalunya = try XCTUnwrap(stops.first { $0.id == "PC2" })
        XCTAssertEqual(plaçaCatalunya.wheelchairBoarding, 1)
        XCTAssertEqual(stops.first { $0.id == "PR1" }?.wheelchairBoarding, 0)
        // A row without the field keeps no state instead of inventing one.
        let bare = FGCParser.stops(fromRecords: [["stop_id": "XX", "stop_name": "X"]])
        XCTAssertNil(bare.first?.wheelchairBoarding)
        // The portal also publishes the GTFS value as a string.
        let textual = FGCParser.stops(fromRecords: [["stop_id": "YY", "wheelchair_boarding": "2"]])
        XCTAssertEqual(textual.first?.wheelchairBoarding, 2)
    }

    func testFGCStationJoinCarriesWheelchairBoarding() throws {
        let stops = try FGCParser.stops(from: fixture("fgc-stops-page1"))
        let stations = FGCNetwork.stations(
            [
                FGCStation(code: "CO", name: "Cornellà Riera", networkLine: 2, order: 1, point: nil),
                FGCStation(code: "PC", name: "Plaça Catalunya", networkLine: 1, order: 1, point: nil),
                FGCStation(code: "ZZ", name: "Inexistent", networkLine: 1, order: 2, point: nil),
            ],
            points: FGCNetwork.stopIndex(stops)
        )
        // Exact row "CO" wins over its platform copies.
        XCTAssertEqual(stations.first { $0.code == "CO" }?.wheelchairBoarding, 1)
        // Only platform rows ("PC2") exist for "PC": the prefix join carries
        // the platform's state.
        XCTAssertEqual(stations.first { $0.code == "PC" }?.wheelchairBoarding, 1)
        // Coordinates still join exactly as before.
        XCTAssertNotNil(stations.first { $0.code == "CO" }?.point)
        XCTAssertNil(stations.first { $0.code == "ZZ" }?.wheelchairBoarding)
        XCTAssertNil(stations.first { $0.code == "ZZ" }?.point)
    }

    /// Platform rows can disagree, so the fallback must be deterministic: the
    /// alphabetically first platform row of the station wins.
    func testFGCBoardingPrefixFallbackIsDeterministic() {
        let stops = FGCParser.stops(fromRecords: [
            ["stop_id": "BA2", "wheelchair_boarding": 1],
            ["stop_id": "BA1", "wheelchair_boarding": 2],
        ])
        let index = FGCNetwork.stopIndex(stops)
        XCTAssertEqual(FGCNetwork.boarding(for: "BA1", in: index), 2)
        XCTAssertEqual(FGCNetwork.boarding(for: "BA", in: index), 2)
        XCTAssertNil(FGCNetwork.boarding(for: "AB", in: index))
    }

    func testFGCStationsWithoutBoardingRowsKeepNil() throws {
        let stations = FGCNetwork.stations(
            [FGCStation(code: "GR", name: "Gràcia", networkLine: 1, order: 3, point: nil)],
            points: FGCNetwork.stopIndex([FGCStop(id: "GR", name: "Gràcia", point: nil)])
        )
        XCTAssertNil(try XCTUnwrap(stations.first).wheelchairBoarding)
    }
}
