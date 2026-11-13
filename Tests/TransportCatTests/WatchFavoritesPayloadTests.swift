import XCTest
@testable import TransportCat

/// `WatchFavoritesPayload` (review W16): the wire shape between the phone and
/// the watch. One type compiled by both targets is what keeps them from
/// drifting, and the list travelling whole is what makes a removal and the
/// rider's order reach the wrist.
final class WatchFavoritesPayloadTests: XCTestCase {
    private func place(code: String = "128", name: String = "Catalunya") -> Place {
        Place(
            kind: .metroStation,
            code: code,
            name: name,
            position: GeoPoint(latitude: 41.385, longitude: 2.170),
            lineCodes: ["L1", "L3"],
            accessible: true
        )
    }

    func testRoundTripKeepsTheOrderAndTheDate() throws {
        let syncedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let payload = WatchFavoritesPayload(
            places: [place(code: "128"), place(code: "129", name: "Diagonal")],
            syncedAt: syncedAt
        )

        let data = try XCTUnwrap(payload.encoded())
        let decoded = try XCTUnwrap(WatchFavoritesPayload.decoded(from: data))

        XCTAssertEqual(decoded, payload)
        XCTAssertEqual(decoded.places.map(\.name), ["Catalunya", "Diagonal"])
        XCTAssertEqual(decoded.syncedAt.timeIntervalSince1970, 1_700_000_000, accuracy: 0.001)
    }

    func testEmptyListIsAPayloadNotASilence() throws {
        let payload = WatchFavoritesPayload(places: [], syncedAt: Date(timeIntervalSince1970: 1_700_000_000))

        let data = try XCTUnwrap(payload.encoded())
        let decoded = try XCTUnwrap(WatchFavoritesPayload.decoded(from: data))

        XCTAssertTrue(decoded.places.isEmpty)
        XCTAssertNotNil(decoded.syncedAt, "an empty list still says when the phone made it")
    }

    func testContextCarriesThePayloadUnderTheVersionedKey() throws {
        let payload = WatchFavoritesPayload(places: [place()], syncedAt: Date(timeIntervalSince1970: 1))
        let context = payload.applicationContext

        XCTAssertEqual(Array(context.keys), [WatchFavoritesPayload.contextKey])
        XCTAssertNotNil(context[WatchFavoritesPayload.contextKey] as? Data)
        XCTAssertEqual(WatchFavoritesPayload.from(context: context), payload)
    }

    func testAnotherOrMissingKeyIsNoPayload() {
        XCTAssertNil(WatchFavoritesPayload.from(context: [:]))
        XCTAssertNil(WatchFavoritesPayload.from(context: ["favorites": Data("[]".utf8)]))
        XCTAssertNil(
            WatchFavoritesPayload.from(context: [WatchFavoritesPayload.contextKey: Data("not json".utf8)])
        )
        XCTAssertNil(
            WatchFavoritesPayload.from(context: [WatchFavoritesPayload.contextKey: "a string"])
        )
    }

    func testTheVersionOneListDidNotCarryADate() throws {
        // A v1 context held a bare `[Place]` array, so it must not decode as a
        // payload: the watch then says "not synced yet" instead of inventing a
        // date.
        let legacy = try JSONEncoder().encode([place()])
        let context: [String: Any] = ["favorites": legacy]

        XCTAssertNil(WatchFavoritesPayload.from(context: context))
        XCTAssertNil(WatchFavoritesPayload.decoded(from: legacy))
    }
}
