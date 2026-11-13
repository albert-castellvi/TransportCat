import XCTest
@testable import TransportCat

/// `WatchRecentSearches` (review W9): typing on a watch costs a dictation, so
/// the search screen offers the queries that already worked.
final class WatchRecentSearchesTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "TransportCatWatchRecentsTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        if let suiteName {
            defaults.removePersistentDomain(forName: suiteName)
        }
        try super.tearDownWithError()
    }

    func testNothingRecordedYet() {
        XCTAssertEqual(WatchRecentSearches.read(from: defaults), [])
    }

    func testNewestFirst() {
        WatchRecentSearches.record("Sagrera", defaults: defaults)
        WatchRecentSearches.record("Diagonal", defaults: defaults)

        XCTAssertEqual(WatchRecentSearches.read(from: defaults), ["Diagonal", "Sagrera"])
    }

    func testSameQueryInAnotherCaseOrAccentIsOneEntry() {
        WatchRecentSearches.record("Sagrera", defaults: defaults)
        WatchRecentSearches.record("  sagrerà ", defaults: defaults)

        XCTAssertEqual(
            WatchRecentSearches.read(from: defaults),
            ["sagrerà"],
            "the entry is remembered as typed, but only once"
        )
    }

    func testRecordingAnOldQueryMovesItToTheFront() {
        WatchRecentSearches.record("Sagrera", defaults: defaults)
        WatchRecentSearches.record("Diagonal", defaults: defaults)
        WatchRecentSearches.record("Sagrera", defaults: defaults)

        XCTAssertEqual(WatchRecentSearches.read(from: defaults), ["Sagrera", "Diagonal"])
    }

    func testKeepsTheLastThreeOnly() {
        for query in ["Sagrera", "Diagonal", "Catalunya", "Espanya"] {
            WatchRecentSearches.record(query, defaults: defaults)
        }

        XCTAssertEqual(WatchRecentSearches.read(from: defaults), ["Espanya", "Catalunya", "Diagonal"])
    }

    func testBlankQueriesAreIgnored() {
        WatchRecentSearches.record("   ", defaults: defaults)
        WatchRecentSearches.record("", defaults: defaults)

        XCTAssertEqual(WatchRecentSearches.read(from: defaults), [])
    }

    func testRecordReturnsTheStoredList() {
        let stored = WatchRecentSearches.record("Sagrera", defaults: defaults)

        XCTAssertEqual(stored, WatchRecentSearches.read(from: defaults))
        XCTAssertEqual(stored, ["Sagrera"])
    }
}
