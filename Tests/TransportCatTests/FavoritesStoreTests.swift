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

    func testMoveReordersPlacesAndPersistsAcrossInstances() {
        let store = FavoritesStore(defaults: defaults)
        let a = place(code: "1", name: "A")
        let b = place(code: "2", name: "B")
        let c = place(code: "3", name: "C")
        store.toggle(a)
        store.toggle(b)
        store.toggle(c)
        XCTAssertEqual(store.favoritePlaces.map(\.name), ["A", "B", "C"])

        // Drag the first place to the end (destination is the pre-move offset).
        store.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        XCTAssertEqual(store.favoritePlaces.map(\.name), ["B", "C", "A"])

        // The order is written to the same defaults, so a new instance reads it.
        let reopened = FavoritesStore(defaults: defaults)
        XCTAssertEqual(reopened.favoritePlaces.map(\.name), ["B", "C", "A"])
        XCTAssertEqual(reopened.favoritePlaces, [b, c, a])
    }

    func testMoveToFront() {
        let store = FavoritesStore(defaults: defaults)
        let a = place(code: "1", name: "A")
        let b = place(code: "2", name: "B")
        let c = place(code: "3", name: "C")
        store.toggle(a)
        store.toggle(b)
        store.toggle(c)

        store.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        XCTAssertEqual(store.favoritePlaces.map(\.name), ["C", "A", "B"])
    }

    func testMoveToMiddle() {
        let store = FavoritesStore(defaults: defaults)
        let a = place(code: "1", name: "A")
        let b = place(code: "2", name: "B")
        let c = place(code: "3", name: "C")
        let d = place(code: "4", name: "D")
        store.toggle(a)
        store.toggle(b)
        store.toggle(c)
        store.toggle(d)

        // Drag the first place between B and C.
        store.move(fromOffsets: IndexSet(integer: 0), toOffset: 2)
        XCTAssertEqual(store.favoritePlaces.map(\.name), ["B", "A", "C", "D"])
    }

    func testMoveOnlyTouchesPlacesNotLines() {
        let store = FavoritesStore(defaults: defaults)
        store.toggle(line(operator: "metro", code: "1"))
        store.toggle(line(operator: "fgc", code: "S1"))
        store.toggle(place(code: "1", name: "A"))
        store.toggle(place(code: "2", name: "B"))

        store.move(fromOffsets: IndexSet(integer: 0), toOffset: 2)

        XCTAssertEqual(store.favoritePlaces.map(\.name), ["B", "A"])
        XCTAssertEqual(store.favoriteLines.map(\.id), ["metro:1", "fgc:S1"])
    }

    /// `.onDelete` in Configuració's editable favourites list: the removed
    /// places leave the persisted list in one step and the order of the rest
    /// is untouched.
    func testRemoveAtOffsetsDeletesPlacesAndPersists() {
        let store = FavoritesStore(defaults: defaults)
        let a = place(code: "1", name: "A")
        let b = place(code: "2", name: "B")
        let c = place(code: "3", name: "C")
        store.toggle(a)
        store.toggle(b)
        store.toggle(c)
        store.toggle(line())

        store.remove(atOffsets: IndexSet(integer: 1))

        XCTAssertEqual(store.favoritePlaces, [a, c])
        XCTAssertFalse(store.isFavorite(b))
        XCTAssertEqual(store.favoriteLines.map(\.id), ["metro:1"])

        let reopened = FavoritesStore(defaults: defaults)
        XCTAssertEqual(reopened.favoritePlaces, [a, c])
    }

    func testRemoveAtSeveralOffsetsKeepsTheUntouchedOnesInOrder() {
        let store = FavoritesStore(defaults: defaults)
        for (code, name) in [("1", "A"), ("2", "B"), ("3", "C"), ("4", "D")] {
            store.toggle(place(code: code, name: name))
        }

        store.remove(atOffsets: IndexSet([0, 2]))

        XCTAssertEqual(store.favoritePlaces.map(\.name), ["B", "D"])
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

    // MARK: - App Group migration

    private func legacySource() throws -> UserDefaults {
        let name = "TransportCatLegacyTests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return try XCTUnwrap(UserDefaults(suiteName: name))
    }

    func testLegacyFavoritesAreCopiedIntoTheGroup() throws {
        let legacy = try legacySource()
        let before = FavoritesStore(defaults: legacy)
        before.toggle(place())
        before.toggle(line())

        FavoritesStore.migrateLegacy(from: legacy, to: defaults)

        let migrated = FavoritesStore(defaults: defaults)
        XCTAssertEqual(migrated.favoritePlaces, [place()])
        XCTAssertEqual(migrated.favoriteLines, [line()])
    }

    func testMigrationNeverOverwritesGroupFavorites() throws {
        let legacy = try legacySource()
        FavoritesStore(defaults: legacy).toggle(place(code: "1", name: "Old"))
        FavoritesStore(defaults: defaults).toggle(place(code: "2", name: "New"))

        FavoritesStore.migrateLegacy(from: legacy, to: defaults)

        XCTAssertEqual(FavoritesStore(defaults: defaults).favoritePlaces, [place(code: "2", name: "New")])
    }
}
