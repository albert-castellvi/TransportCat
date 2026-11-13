import XCTest
@testable import TransportCat

/// The place side of Rodalies: the new `PlaceKind` case, the mapping from the
/// topology to `Place`, and the search/nearby rules that must see them.
final class RodaliesPlacesTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        #if os(Linux)
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") else {
            XCTFail("Missing fixture \(name).json")
            throw RodaliesError.unexpectedPayload("missing fixture \(name)")
        }
        return try Data(contentsOf: url)
        #else
        guard let url = Bundle(for: RodaliesPlacesTests.self).url(forResource: name, withExtension: "json") else {
            XCTFail("Missing fixture \(name).json")
            throw RodaliesError.unexpectedPayload("missing fixture \(name)")
        }
        return try Data(contentsOf: url)
        #endif
    }

    private func topology() throws -> RodaliesTopology {
        try XCTUnwrap(RodaliesTopology.decode(try fixture("rodalies-topology")))
    }

    // MARK: - PlaceKind

    /// The new case is additive: the raw values already persisted (inside
    /// `Place.id` and `FavoritesStore`) keep decoding.
    func testPlaceKindIsAdditive() {
        XCTAssertEqual(PlaceKind(rawValue: "metroStation"), .metroStation)
        XCTAssertEqual(PlaceKind(rawValue: "busStop"), .busStop)
        XCTAssertEqual(PlaceKind(rawValue: "fgcStation"), .fgcStation)
        XCTAssertEqual(PlaceKind(rawValue: "rodaliesStation"), .rodaliesStation)
        XCTAssertNil(PlaceKind(rawValue: "rodalies"))

        let legacy = Place(
            kind: .fgcStation,
            code: "GR",
            name: "Gràcia",
            position: GeoPoint(latitude: 41.4, longitude: 2.15),
            lineCodes: ["S1"],
            accessible: nil
        )
        XCTAssertEqual(legacy.id, "fgcStation:GR")
        XCTAssertEqual(PlaceKind.allCases.contains(.rodaliesStation), true)
    }

    /// A place round-trips through the cache the way `DiskCache` stores it.
    func testRodaliesPlaceSurvivesEncoding() throws {
        let place = Place(
            kind: .rodaliesStation,
            code: "71801",
            name: "Barcelona-Sants",
            position: GeoPoint(latitude: 41.379, longitude: 2.14),
            lineCodes: ["R1", "R16"],
            accessible: true
        )
        let data = try JSONEncoder().encode([place])
        let decoded = try JSONDecoder().decode([Place].self, from: data)
        XCTAssertEqual(decoded, [place])
        XCTAssertEqual(decoded.first?.id, "rodaliesStation:71801")
    }

    // MARK: - Topology to place

    func testStationsBecomePlacesWithLineCodesAndAccessibility() throws {
        let places = TMBPlaceParser.rodaliesPlaces(stations: try topology().stations)
        // Alphabetical by folded name, the catalog's own order.
        XCTAssertEqual(places.map(\.code), ["71802", "71801", "72305", "71500"])
        XCTAssertTrue(places.allSatisfy { $0.kind == .rodaliesStation })

        let sants = try XCTUnwrap(places.first { $0.code == "71801" })
        XCTAssertEqual(sants.name, "Barcelona-Sants")
        XCTAssertEqual(sants.lineCodes, ["R1", "R16"])
        XCTAssertEqual(sants.accessible, true)
        XCTAssertEqual(sants.position.latitude, 41.379, accuracy: 1e-7)

        // wheelchair_boarding 2 means not accessible; the mapping must not
        // confuse it with "no information".
        XCTAssertEqual(places.first { $0.code == "71500" }?.accessible, false)
    }

    func testUnknownAccessibilityStaysUnknown() {
        let stations = [
            RodaliesStation(
                id: "1",
                name: "Sense dades",
                latitude: 41.0,
                longitude: 2.0,
                lineCodes: ["R1"],
                wheelchairBoarding: 0
            ),
            RodaliesStation(
                id: "2",
                name: "Sense camp",
                latitude: 41.1,
                longitude: 2.1,
                lineCodes: ["R1"],
                wheelchairBoarding: nil
            ),
        ]
        let places = TMBPlaceParser.rodaliesPlaces(stations: stations)
        XCTAssertNil(places.first { $0.code == "1" }?.accessible)
        XCTAssertNil(places.first { $0.code == "2" }?.accessible)
    }

    // MARK: - Search and nearby

    /// Search, favourites and the nearby list all read the same catalog: a
    /// Rodalies place must behave like any other there.
    func testRodaliesPlacesAreSearchableAndNearby() throws {
        let places = TMBPlaceParser.rodaliesPlaces(stations: try topology().stations)
        let found = PlaceIndex.search(query: "sants", places: places)
        XCTAssertEqual(found.first?.code, "71801")
        XCTAssertEqual(found.first?.kind, .rodaliesStation)

        let nearby = PlaceIndex.nearest(
            to: GeoPoint(latitude: 41.379, longitude: 2.14),
            places: places,
            limit: 2,
            maxDistance: 2_000
        )
        XCTAssertEqual(nearby.first?.place.code, "71801")

        // A diacritic-insensitive search must still hit the accent-free spelling
        // of a Catalan station name.
        XCTAssertEqual(PlaceIndex.search(query: "gracia", places: places).first?.code, "71802")
    }

    /// What the app ships is what the catalog gets: the bundled topology feeds
    /// `PlaceCatalogStore` without a request.
    func testBundledTopologyFeedsThePlaceCatalog() throws {
        let bundled = try XCTUnwrap(RodaliesTopology.bundled)
        let places = TMBPlaceParser.rodaliesPlaces(stations: bundled.stations)
        XCTAssertEqual(places.count, bundled.stations.count)
        XCTAssertTrue(places.allSatisfy { $0.kind == .rodaliesStation })
        XCTAssertTrue(places.allSatisfy { !$0.lineCodes.isEmpty })
        XCTAssertFalse(PlaceIndex.search(query: "barcelona-sants", places: places).isEmpty)
    }
}
