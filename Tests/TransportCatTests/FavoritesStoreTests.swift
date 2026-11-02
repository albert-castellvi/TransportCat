import XCTest
@testable import TransportCat

/// `FavoritesStore` (spec S4): favorite places under `favoritePlaces.v1` and
/// favorite metro/FGC lines under `favoriteLines.v1`. Bus line favorites stay
/// in `BusCatalogStore`'s `busFavorites` key, so this store never writes them.
final class FavoritesStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "TransportCatFavoritesTests-\(UUID().uuidString)"
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
            lineCodes: ["1"],
            accessible: true
        )
    }

    private func line(operator name: String = "metro", code: String = "1") -> FavoriteLine {
        FavoriteLine(operator: name, code: code)
    }

    // MARK: - Places

    func testPlaceTogglePersistsAcrossInstances() throws {
        let store = FavoritesStore(defaults: defaults)
        let catalunya = place()

        XCTAssertFalse(store.isFavorite(catalunya))
        store.toggle(catalunya)

        XCTAssertTrue(store.isFavorite(catalunya))
        XCTAssertEqual(store.favoritePlaces, [catalunya])
        XCTAssertNotNil(defaults.data(forKey: "favoritePlaces.v1"))

        let reopened = FavoritesStore(defaults: defaults)
        XCTAssertTrue(reopened.isFavorite(catalunya))
        XCTAssertEqual(reopened.favoritePlaces, [catalunya])
    }

    func testPlaceToggleTwiceRemovesIt() {
        let store = FavoritesStore(defaults: defaults)
        store.toggle(place())
        store.toggle(place())
        XCTAssertTrue(store.favoritePlaces.isEmpty)
        XCTAssertFalse(store.isFavorite(place()))
    }

    // MARK: - Lines

    func testLineTogglePersistsAcrossInstances() {
        let store = FavoritesStore(defaults: defaults)
        let l1 = line()

        store.toggle(l1)
        XCTAssertTrue(store.isFavorite(l1))
        XCTAssertEqual(store.favoriteLines.map(\.id), ["metro:1"])

        let reopened = FavoritesStore(defaults: defaults)
        XCTAssertEqual(reopened.favoriteLines, [l1])
        XCTAssertTrue(reopened.isFavorite(l1))
        XCTAssertFalse(reopened.isFavorite(line(operator: "fgc", code: "S1")))
    }

    func testFavoriteLineIdentityUsesOperatorAndCode() {
        let metro = line(operator: "metro", code: "S1")
        let fgc = line(operator: "fgc", code: "S1")
        XCTAssertNotEqual(metro.id, fgc.id)

        let store = FavoritesStore(defaults: defaults)
        store.toggle(metro)
        XCTAssertTrue(store.isFavorite(metro))
        XCTAssertFalse(store.isFavorite(fgc))
    }

    func testLinesAndPlacesDoNotOverwriteEachOther() {
        let store = FavoritesStore(defaults: defaults)
        store.toggle(place())
        store.toggle(line())

        let reopened = FavoritesStore(defaults: defaults)
        XCTAssertEqual(reopened.favoritePlaces.count, 1)
        XCTAssertEqual(reopened.favoriteLines.count, 1)
    }

    // MARK: - Tolerance

    func testGarbageInDefaultsReadsAsEmpty() {
        defaults.set(Data("garbage".utf8), forKey: "favoritePlaces.v1")
        defaults.set(["not", "our", "shape"], forKey: "favoriteLines.v1")

        let store = FavoritesStore(defaults: defaults)
        XCTAssertTrue(store.favoritePlaces.isEmpty)
        XCTAssertTrue(store.favoriteLines.isEmpty)
    }

    func testBusFavoritesKeyIsNeverTouched() {
        defaults.set([212], forKey: "busFavorites")
        let store = FavoritesStore(defaults: defaults)
        store.toggle(place())
        store.toggle(line())
        XCTAssertEqual(defaults.array(forKey: "busFavorites") as? [Int], [212])
    }
}
