import XCTest
@testable import TransportCat

/// `WatchFavoritesStore` (review W16): the watch side of the favourites sync.
/// The list is replaced whole, so a place unstared on the phone really goes and
/// the order the rider set in Explora is the order on the wrist.
///
/// The store is `@MainActor`, so each test that touches it is annotated instead
/// of the whole class: `setUpWithError` has to stay nonisolated to override the
/// XCTest one.
final class WatchFavoritesStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "TransportCatWatchFavoritesTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        if let suiteName {
            defaults.removePersistentDomain(forName: suiteName)
        }
        try super.tearDownWithError()
    }

    private func place(code: String = "128", name: String = "Catalunya") -> Place {
        Place(
            kind: .metroStation,
            code: code,
            name: name,
            position: GeoPoint(latitude: 41.385, longitude: 2.170),
            lineCodes: ["L1"],
            accessible: nil
        )
    }

    private func payload(_ places: [Place], at seconds: TimeInterval = 1_700_000_000) -> WatchFavoritesPayload {
        WatchFavoritesPayload(places: places, syncedAt: Date(timeIntervalSince1970: seconds))
    }

    @MainActor
    func testAWatchThatNeverSyncedHasNothingAndNoDate() {
        let store = WatchFavoritesStore(defaults: defaults)

        XCTAssertTrue(store.places.isEmpty)
        XCTAssertNil(store.syncedAt, "the empty state has to tell 'never synced' from 'no favorites'")
    }

    @MainActor
    func testReplaceFollowsThePhonesOrderAndPersists() throws {
        let catalunya = place(code: "128", name: "Catalunya")
        let diagonal = place(code: "129", name: "Diagonal")
        let store = WatchFavoritesStore(defaults: defaults)

        XCTAssertTrue(store.replace(with: payload([diagonal, catalunya])))

        XCTAssertEqual(store.places.map(\.name), ["Diagonal", "Catalunya"])
        XCTAssertEqual(store.syncedAt, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertNotNil(defaults.data(forKey: WatchFavoritesPayload.storedKey))

        let reopened = WatchFavoritesStore(defaults: defaults)
        XCTAssertEqual(reopened.places.map(\.name), ["Diagonal", "Catalunya"])
        XCTAssertEqual(reopened.syncedAt, Date(timeIntervalSince1970: 1_700_000_000))
    }

    @MainActor
    func testReorderOnThePhoneReachesTheWatch() {
        let catalunya = place(code: "128", name: "Catalunya")
        let diagonal = place(code: "129", name: "Diagonal")
        let store = WatchFavoritesStore(defaults: defaults)
        store.replace(with: payload([catalunya, diagonal], at: 1_700_000_000))

        store.replace(with: payload([diagonal, catalunya], at: 1_700_000_100))

        XCTAssertEqual(store.places.map(\.name), ["Diagonal", "Catalunya"])
        XCTAssertEqual(store.syncedAt, Date(timeIntervalSince1970: 1_700_000_100))
    }

    @MainActor
    func testAPlaceRemovedOnThePhoneIsDroppedHere() {
        let catalunya = place(code: "128", name: "Catalunya")
        let diagonal = place(code: "129", name: "Diagonal")
        let store = WatchFavoritesStore(defaults: defaults)
        store.replace(with: payload([catalunya, diagonal], at: 1_700_000_000))

        store.replace(with: payload([catalunya], at: 1_700_000_100))

        XCTAssertEqual(store.places.map(\.name), ["Catalunya"])
        XCTAssertFalse(store.places.contains(diagonal), "the list is a replacement, never a merge")
    }

    @MainActor
    func testAnEmptyListStillDatedIsAValidSync() {
        let store = WatchFavoritesStore(defaults: defaults)
        store.replace(with: payload([place()], at: 1_700_000_000))

        store.replace(with: payload([], at: 1_700_000_100))

        XCTAssertTrue(store.places.isEmpty)
        XCTAssertNotNil(store.syncedAt, "the phone did sync, it just has no favorites")
    }

    @MainActor
    func testReplaceReportsWhetherAnythingChanged() {
        let catalunya = place()
        let store = WatchFavoritesStore(defaults: defaults)

        XCTAssertTrue(store.replace(with: payload([catalunya])))
        XCTAssertFalse(store.replace(with: payload([catalunya])), "same list and same date: nothing to write")
        XCTAssertTrue(store.replace(with: payload([catalunya], at: 1_700_000_100)))
    }

    @MainActor
    func testAValueOfAnotherShapeReadsAsNothingSynced() throws {
        // A bare `[Place]` array is what the v1 keys held and what a future
        // shape might hold: it must read as "nothing synced yet", never as a
        // crash and never as a guess.
        defaults.set(try JSONEncoder().encode([place()]), forKey: WatchFavoritesPayload.storedKey)

        let store = WatchFavoritesStore(defaults: defaults)

        XCTAssertTrue(store.places.isEmpty)
        XCTAssertNil(store.syncedAt)
    }
}
