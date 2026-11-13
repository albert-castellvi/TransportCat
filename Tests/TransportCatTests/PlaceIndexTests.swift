import XCTest
@testable import TransportCat

/// Pure rules of `PlaceIndex` (spec S1): search ranking, diacritics, nearest
/// places and interchanges. Everything is deterministic and clock-free.
final class PlaceIndexTests: XCTestCase {
    // MARK: - Helpers

    private func place(
        kind: PlaceKind = .metroStation,
        code: String,
        name: String,
        latitude: Double = 41.385,
        longitude: Double = 2.170,
        lines: [String] = [],
        accessible: Bool? = nil
    ) -> Place {
        Place(
            kind: kind,
            code: code,
            name: name,
            position: GeoPoint(latitude: latitude, longitude: longitude),
            lineCodes: lines,
            accessible: accessible
        )
    }

    // MARK: - Identity (S1)

    func testIdentityIsKindAndCode() {
        let place = place(code: "128", name: "Catalunya")
        XCTAssertEqual(place.id, "metroStation:128")
        XCTAssertEqual(place, place)
        XCTAssertEqual(Set([place, place]).count, 1)
    }

    func testPlaceKindIsCodable() throws {
        let encoded = try JSONEncoder().encode(PlaceKind.busStop)
        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), "\"busStop\"")
        let decoded = try JSONDecoder().decode(PlaceKind.self, from: encoded)
        XCTAssertEqual(decoded, .busStop)
    }

    // MARK: - Search (S1)

    func testSearchIsCaseAndDiacriticInsensitive() {
        let places = [
            place(code: "1", name: "Plaça Catalunya"),
            place(code: "2", name: "Perdany"),
        ]
        XCTAssertEqual(PlaceIndex.search(query: "placa catalunya", places: places, limit: 10).map(\.code), ["1"])
        XCTAssertEqual(PlaceIndex.search(query: "PERDANY", places: places, limit: 10).map(\.code), ["2"])
        XCTAssertEqual(PlaceIndex.search(query: "  perdany ", places: places, limit: 10).map(\.code), ["2"])
    }

    func testPrefixMatchesRankBeforeSubstringMatches() {
        let places = [
            place(code: "1", name: "Camp de l'Arpa"),
            place(code: "2", name: "Arpa"),
            place(code: "3", name: "Sant Arpa"),
        ]
        let found = PlaceIndex.search(query: "arpa", places: places, limit: 10)
        // "Arpa" starts with the query, so it comes before the two substrings.
        XCTAssertEqual(found.first?.code, "2")
    }

    func testWordPrefixMatchesRankBeforeInnerSubstring() {
        let places = [
            place(code: "1", name: "Els Encants"),
            place(code: "2", name: "Plaça Catalunya"),
            place(code: "3", name: "Catalogne"),
        ]
        let found = PlaceIndex.search(query: "catalunya", places: places, limit: 10)
        XCTAssertEqual(found.map(\.code), ["2"])
        // "Catalogne" starts with the query, "Catalunya" only at a word start.
        XCTAssertEqual(PlaceIndex.search(query: "catal", places: places, limit: 10).map(\.code), ["3", "2"])
    }

    /// Rodalies names the terminus with a hyphen ("Barcelona-Sants"), and the
    /// catalogues also join with dots and middots. The part after the separator
    /// is a word: a rider typing it means that station.
    func testPunctuationSeparatesWordsLikeWhitespaceDoes() {
        let places = [
            place(kind: .rodaliesStation, code: "rod", name: "Barcelona-Sants"),
            place(kind: .fgcStation, code: "fgc", name: "Barcelona-Passeig de Gràcia"),
            place(code: "metro", name: "Pl. Catalunya"),
        ]
        XCTAssertEqual(PlaceIndex.hasWordPrefix("barcelona-sants", "sants"), true)
        XCTAssertEqual(PlaceIndex.hasWordPrefix("pl. catalunya", "catalunya"), true)
        XCTAssertEqual(
            PlaceIndex.search(query: "sants", places: places, limit: 10).map(\.code),
            ["rod"]
        )
        XCTAssertEqual(
            PlaceIndex.search(query: "passeig", places: places, limit: 10).map(\.code),
            ["fgc"]
        )
        XCTAssertEqual(
            PlaceIndex.search(query: "catalunya", places: places, limit: 10).map(\.code),
            ["metro"]
        )
    }

    func testSearchHonoursTheLimit() {
        let places = (1...10).map { place(code: "\($0)", name: "Estació \($0)") }
        XCTAssertEqual(PlaceIndex.search(query: "estacio", places: places, limit: 3).count, 3)
        XCTAssertTrue(PlaceIndex.search(query: "estacio", places: places, limit: 0).isEmpty)
    }

    func testEmptyQueryFindsNothing() {
        let places = [place(code: "1", name: "Catalunya")]
        XCTAssertTrue(PlaceIndex.search(query: "", places: places, limit: 10).isEmpty)
        XCTAssertTrue(PlaceIndex.search(query: "   ", places: places, limit: 10).isEmpty)
    }

    func testSearchOrderIsStableForEqualNames() {
        let places = [
            place(code: "b", name: "Catalunya"),
            place(code: "a", name: "Catalunya"),
        ]
        XCTAssertEqual(PlaceIndex.search(query: "catalunya", places: places, limit: 10).map(\.code), ["a", "b"])
    }

    // MARK: - Nearest (S1)

    func testNearestReturnsPlacesWithDistanceInMeters() {
        let origin = GeoPoint(latitude: 41.385, longitude: 2.170)
        let near = place(code: "near", name: "A prop", latitude: 41.3851, longitude: 2.1701)
        let far = place(code: "far", name: "Lluny", latitude: 41.400, longitude: 2.170)

        let found = PlaceIndex.nearest(to: origin, places: [far, near], limit: 10, maxDistance: 5_000)
        XCTAssertEqual(found.map(\.place.code), ["near", "far"])
        XCTAssertLessThan(found[0].distance, found[1].distance)
        XCTAssertEqual(found[0].distance, 13, accuracy: 3)
        XCTAssertEqual(found[0].id, "metroStation:near")
    }

    func testNearestDropsPlacesBeyondMaxDistance() {
        let origin = GeoPoint(latitude: 41.385, longitude: 2.170)
        let inside = place(code: "in", name: "Dins", latitude: 41.3855, longitude: 2.170)
        let outside = place(code: "out", name: "Fora", latitude: 41.500, longitude: 2.170)

        let found = PlaceIndex.nearest(to: origin, places: [inside, outside], limit: 10, maxDistance: 1_000)
        XCTAssertEqual(found.map(\.place.code), ["in"])
        XCTAssertTrue(PlaceIndex.nearest(to: origin, places: [outside], limit: 10).isEmpty)
    }

    func testNearestHonoursTheLimit() {
        let origin = GeoPoint(latitude: 41.385, longitude: 2.170)
        let places = (1...5).map { index in
            place(code: "\(index)", name: "Estació \(index)", latitude: 41.385 + Double(index) / 10_000, longitude: 2.170)
        }
        XCTAssertEqual(PlaceIndex.nearest(to: origin, places: places, limit: 2, maxDistance: 10_000).count, 2)
    }

    // MARK: - Interchanges (S1)

    func testInterchangesIncludeNearbyPlacesAndSameNameMetroStations() {
        let here = place(kind: .metroStation, code: "128", name: "Catalunya", lines: ["L1"])
        // A different physical station sharing the name, far away.
        let sameName = place(kind: .metroStation, code: "999", name: "Catalunya", latitude: 41.500, longitude: 2.200, lines: ["L3"])
        // A bus stop 40 m away.
        let nearbyStop = place(kind: .busStop, code: "384", name: "Sant Antoni Maria Claret", latitude: 41.3853, longitude: 2.1701)
        // Far away and a different name: not an interchange.
        let farStop = place(kind: .busStop, code: "1", name: "Lluny", latitude: 41.500, longitude: 2.200)

        let found = PlaceIndex.interchanges(for: here, places: [here, sameName, nearbyStop, farStop])
        XCTAssertEqual(Set(found.map(\.id)), Set([sameName.id, nearbyStop.id]))
        XCTAssertFalse(found.contains { $0.id == here.id })
    }

    func testInterchangesRespectTheRadius() {
        let here = place(code: "1", name: "Centre")
        let nearby = place(kind: .busStop, code: "2", name: "Parada", latitude: 41.3855, longitude: 2.170)
        let far = place(kind: .busStop, code: "3", name: "Lluny", latitude: 41.3865, longitude: 2.170)

        XCTAssertEqual(PlaceIndex.interchanges(for: here, places: [nearby, far], radius: 100).map(\.code), ["2"])
        XCTAssertEqual(PlaceIndex.interchanges(for: here, places: [nearby, far], radius: 150).map(\.code), ["2"])
        XCTAssertEqual(Set(PlaceIndex.interchanges(for: here, places: [nearby, far], radius: 200).map(\.code)), ["2", "3"])
    }
}
