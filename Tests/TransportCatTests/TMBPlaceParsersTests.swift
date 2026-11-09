import XCTest
@testable import TransportCat

/// Parsers of the all-network place endpoints (spec S2). Fixtures are shaped
/// exactly like the DOC-TMB transit schemas: `/transit/parades` for bus stops
/// and `/transit/linies/metro/{line}/estacions` for metro stations.
final class TMBPlaceParsersTests: XCTestCase {
    // MARK: - Metro

    private func stations(fixture: String, lineCode: String) throws -> [Station] {
        try GeoJSONParser.stations(from: Fixtures.data(fixture), lineCode: lineCode)
    }

    func testMetroPlacesMergeStationsSharingAName() throws {
        let lines = [
            TMBPlaceMetroLine(
                code: "1",
                displayName: "L1",
                stations: try stations(fixture: "places-metro-L1", lineCode: "1")
            ),
            TMBPlaceMetroLine(
                code: "3",
                displayName: "L3",
                stations: try stations(fixture: "places-metro-L3", lineCode: "3")
            ),
        ]

        let places = TMBPlaceParser.metroPlaces(from: lines)
        let catalunya = try XCTUnwrap(places.first { $0.name == "Catalunya" })

        XCTAssertEqual(catalunya.kind, .metroStation)
        XCTAssertEqual(catalunya.lineCodes, ["L1", "L3"])
        XCTAssertEqual(catalunya.accessible, true)
        XCTAssertEqual(places.filter { $0.name == "Catalunya" }.count, 1, "the same station must not appear twice")
        XCTAssertEqual(places.count, 3)
    }

    func testMetroPlaceCodeUsesTheTMBStationID() throws {
        let lines = [
            TMBPlaceMetroLine(code: "1", displayName: "L1", stations: try stations(fixture: "places-metro-L1", lineCode: "1")),
        ]
        let places = TMBPlaceParser.metroPlaces(from: lines)
        let catalunya = try XCTUnwrap(places.first { $0.name == "Catalunya" })
        // ID_ESTACIO is the stable physical station code; CODI_ESTACIO is per line.
        XCTAssertEqual(catalunya.code, "101")
        XCTAssertEqual(catalunya.id, "metroStation:101")
    }

    func testMetroAccessibilityIsFalseWhenAnyLineSaysNotAccessible() throws {
        let lines = [
            TMBPlaceMetroLine(code: "1", displayName: "L1", stations: try stations(fixture: "places-metro-L1", lineCode: "1")),
        ]
        let places = TMBPlaceParser.metroPlaces(from: lines)
        let universitat = try XCTUnwrap(places.first { $0.name == "Universitat" })
        XCTAssertEqual(universitat.accessible, false)
    }

    func testMetroPlacesSortByLineOrderAndName() throws {
        let lines = [
            TMBPlaceMetroLine(code: "1", displayName: "L1", stations: try stations(fixture: "places-metro-L1", lineCode: "1")),
            TMBPlaceMetroLine(code: "3", displayName: "L3", stations: try stations(fixture: "places-metro-L3", lineCode: "3")),
        ]
        let places = TMBPlaceParser.metroPlaces(from: lines)
        XCTAssertEqual(places.map(\.name), ["Catalunya", "Plaça del Centre", "Universitat"])
    }

    // MARK: - Bus

    func testBusNetworkStopsParseCodeNameAndPosition() throws {
        let stops = try TMBPlaceParser.busNetworkStops(from: Fixtures.data("places-bus-network"))
        XCTAssertEqual(stops.count, 3)

        let first = try XCTUnwrap(stops.first { $0.code == 1775 })
        XCTAssertEqual(first.name, "Av Tibidabo - Ronda de Dalt")
        XCTAssertEqual(first.position.latitude, 41.385064, accuracy: 1e-6)
        XCTAssertEqual(first.position.longitude, 2.173403, accuracy: 1e-6)
    }

    func testBusPlacesCollectEveryLineServingAStop() throws {
        let networkStops = try TMBPlaceParser.busNetworkStops(from: Fixtures.data("places-bus-network"))
        let lineStops = [
            TMBPlaceBusLineStops(code: 208, name: "H8", stops: try BusParser.stops(from: Fixtures.data("bus-stops-212"))),
            TMBPlaceBusLineStops(code: 212, name: "H12", stops: try BusParser.stops(from: Fixtures.data("bus-stops-212"))),
        ]

        let places = TMBPlaceParser.busPlaces(stops: networkStops, lines: lineStops)
        // Stop 7 comes from the per-line feed only; both lines serve it.
        let stop = try XCTUnwrap(places.first { $0.code == "7" })

        XCTAssertEqual(stop.kind, .busStop)
        XCTAssertEqual(stop.lineCodes, ["H12", "H8"])
        XCTAssertNil(stop.accessible)

        // The network feed keeps its own coordinates and name.
        let networkOnly = try XCTUnwrap(places.first { $0.code == "1775" })
        XCTAssertEqual(networkOnly.name, "Av Tibidabo - Ronda de Dalt")
    }

    func testBusPlacesAddStopsMissingFromTheNetworkFeed() throws {
        let lineStops = [
            TMBPlaceBusLineStops(code: 212, name: "H12", stops: try BusParser.stops(from: Fixtures.data("bus-stops-212"))),
        ]
        // No network stop at all: the per-line feed still yields places.
        let places = TMBPlaceParser.busPlaces(stops: [], lines: lineStops)
        XCTAssertFalse(places.isEmpty)
        XCTAssertTrue(places.allSatisfy { $0.kind == .busStop && $0.lineCodes == ["H12"] })
    }

    func testBusPlaceCodeIsTheStopCode() throws {
        let networkStops = try TMBPlaceParser.busNetworkStops(from: Fixtures.data("places-bus-network"))
        let places = TMBPlaceParser.busPlaces(stops: networkStops, lines: [])
        let stop = try XCTUnwrap(places.first { $0.code == "3312" })
        XCTAssertEqual(stop.id, "busStop:3312")
    }

    // MARK: - FGC

    private func fgcLine(code: String, polyline: [GeoPoint]) -> FGCLine {
        FGCLine(
            code: code,
            name: "Line \(code)",
            colorHex: "E30613",
            textColorHex: "FFFFFF",
            polylines: [polyline]
        )
    }

    func testFGCPlacesAssignLinesWhoseRoutePassesThroughTheStation() {
        let station = FGCStation(
            code: "GR",
            name: "Gràcia",
            networkLine: 1,
            order: 1,
            point: GeoPoint(latitude: 41.4000, longitude: 2.1500)
        )
        let near = fgcLine(code: "S1", polyline: [
            GeoPoint(latitude: 41.3990, longitude: 2.1500),
            GeoPoint(latitude: 41.4010, longitude: 2.1500),
        ])
        let far = fgcLine(code: "R5", polyline: [
            GeoPoint(latitude: 41.5000, longitude: 2.3000),
            GeoPoint(latitude: 41.5010, longitude: 2.3000),
        ])

        let places = TMBPlaceParser.fgcPlaces(stations: [station], lines: [near, far])
        XCTAssertEqual(places.count, 1)
        XCTAssertEqual(places[0].kind, .fgcStation)
        XCTAssertEqual(places[0].code, "GR")
        XCTAssertEqual(places[0].lineCodes, ["S1"])
        XCTAssertNil(places[0].accessible)
    }

    func testFGCStationsWithoutCoordinatesAreDropped() {
        let station = FGCStation(code: "XX", name: "Sense punt", networkLine: 2, order: 1, point: nil)
        XCTAssertTrue(TMBPlaceParser.fgcPlaces(stations: [station], lines: []).isEmpty)
    }

    /// #24: without a station feed, a line-feed station keeps its own
    /// `CODI_ESTACIO` instead of being asked by its `ID_ESTACIO`.
    func testStationCodeWithoutAFeedKeepsTheStationCode() {
        let station = Station(code: 128, name: "Catalunya", orderInLine: 1, lineCode: "1", latitude: 41.385, longitude: 2.170, id: 101, accessible: true)
        XCTAssertEqual(TMBPlaceParser.stationCode(forStation: station, in: []), 128)
    }
}
