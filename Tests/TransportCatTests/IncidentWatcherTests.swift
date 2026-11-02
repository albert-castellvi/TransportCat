import XCTest
@testable import TransportCat

/// `IncidentWatcher` (spec S14) pure rules: the new-alert diff against the
/// favorite lines, the favorite line-code normalization, the notification
/// title and the rolling window of seen alert ids.
final class IncidentWatcherTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "TransportCatIncidentWatcherTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        if let suiteName {
            defaults.removePersistentDomain(forName: suiteName)
        }
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func alert(id: String, lineCodes: [String], text: String? = nil) -> ServiceAlert {
        ServiceAlert(
            id: id,
            lineCodes: lineCodes,
            stationNames: [],
            beginDate: nil,
            endDate: nil,
            text: text
        )
    }

    // MARK: - newAlerts

    func testNewAlertsKeepsOnlyFavoriteLines() {
        let current = [
            alert(id: "1", lineCodes: ["1"]),
            alert(id: "2", lineCodes: ["3"]),
            alert(id: "3", lineCodes: ["212"]),
        ]
        let fresh = IncidentWatcher.newAlerts(
            current: current,
            favoriteLines: ["1", "212"],
            seen: []
        )
        XCTAssertEqual(fresh.map(\.id), ["1", "3"])
    }

    func testNewAlertsSkipsSeenIDs() {
        let current = [alert(id: "1", lineCodes: ["1"]), alert(id: "2", lineCodes: ["1"])]
        let fresh = IncidentWatcher.newAlerts(
            current: current,
            favoriteLines: ["1"],
            seen: ["1"]
        )
        XCTAssertEqual(fresh.map(\.id), ["2"])
    }

    func testNewAlertsEmitsEachIDOnce() {
        let first = alert(id: "7", lineCodes: ["2"], text: "first")
        let repeated = alert(id: "7", lineCodes: ["2"], text: "repeated copy")
        let fresh = IncidentWatcher.newAlerts(
            current: [first, repeated],
            favoriteLines: ["2"],
            seen: []
        )
        XCTAssertEqual(fresh.count, 1)
        XCTAssertEqual(fresh[0].text, "first", "the first occurrence of an id wins")
    }

    func testNewAlertsPreservesFeedOrder() {
        let current = [
            alert(id: "a", lineCodes: ["4"]),
            alert(id: "b", lineCodes: ["1"]),
            alert(id: "c", lineCodes: ["4", "1"]),
        ]
        let fresh = IncidentWatcher.newAlerts(current: current, favoriteLines: ["4"], seen: [])
        XCTAssertEqual(fresh.map(\.id), ["a", "c"])
    }

    func testNewAlertsWithNoFavoritesIsEmpty() {
        let fresh = IncidentWatcher.newAlerts(
            current: [alert(id: "1", lineCodes: ["1"])],
            favoriteLines: [],
            seen: []
        )
        XCTAssertTrue(fresh.isEmpty)
    }

    func testNewAlertsOfAnAlertWithoutLinesIsEmpty() {
        let fresh = IncidentWatcher.newAlerts(
            current: [alert(id: "1", lineCodes: [])],
            favoriteLines: ["1"],
            seen: []
        )
        XCTAssertTrue(fresh.isEmpty)
    }

    // MARK: - favoriteLineCodes

    func testFavoriteLineCodesResolvesMetroDisplayNames() {
        let codes = IncidentWatcher.favoriteLineCodes(metro: ["1", "L9N"], bus: [212])
        XCTAssertEqual(codes, ["1", "L9N", "94", "212"], "display names resolve to API codes")
    }

    func testFavoriteLineCodesKeepsUnknownCodes() {
        let codes = IncidentWatcher.favoriteLineCodes(metro: ["55"], bus: [])
        XCTAssertEqual(codes, ["55"])
    }

    func testFavoriteLineCodesEmptyFavoritesIsEmpty() {
        XCTAssertTrue(IncidentWatcher.favoriteLineCodes(metro: [], bus: []).isEmpty)
    }

    // MARK: - title

    func testTitleForMetroAlertUsesDisplayName() {
        let title = IncidentWatcher.title(for: alert(id: "1", lineCodes: ["2"]), isBus: false, busNames: [:])
        XCTAssertEqual(title, "Incidència a L2")
    }

    func testTitleForUnknownMetroCodeKeepsCode() {
        let title = IncidentWatcher.title(for: alert(id: "1", lineCodes: ["88"]), isBus: false, busNames: [:])
        XCTAssertEqual(title, "Incidència a 88")
    }

    func testTitleForBusAlertUsesCommercialName() {
        let title = IncidentWatcher.title(
            for: alert(id: "1", lineCodes: ["212"]),
            isBus: true,
            busNames: ["212": "H12"]
        )
        XCTAssertEqual(title, "Incidència a H12")
    }

    func testTitleForBusAlertWithoutNameKeepsCode() {
        let title = IncidentWatcher.title(for: alert(id: "1", lineCodes: ["212"]), isBus: true, busNames: [:])
        XCTAssertEqual(title, "Incidència a 212")
    }

    func testTitleWithoutLineCodes() {
        let title = IncidentWatcher.title(for: alert(id: "1", lineCodes: []), isBus: false, busNames: [:])
        XCTAssertEqual(title, "Incidència a la xarxa")
    }

    // MARK: - seen ids

    func testAppendingSeenIDSkipsDuplicates() {
        let grown = IncidentWatcher.appendingSeen(["1", "2"], id: "2")
        XCTAssertEqual(grown, ["1", "2"])
    }

    func testAppendingSeenIDEvictsOldestBeyondTheCap() {
        let grown = IncidentWatcher.appendingSeen(["1", "2", "3"], id: "4", cap: 3)
        XCTAssertEqual(grown, ["2", "3", "4"])
    }

    func testStoredSeenIDsReadsThePersistedArray() {
        defaults.set(["9", "8"], forKey: IncidentWatcher.seenKey)
        XCTAssertEqual(IncidentWatcher.storedSeenIDs(defaults), ["9", "8"])
    }

    func testStoredSeenIDsTreatsJunkAsEmpty() {
        defaults.set(7, forKey: IncidentWatcher.seenKey)
        XCTAssertEqual(IncidentWatcher.storedSeenIDs(defaults), [])
    }

    // MARK: - enabled flag

    @MainActor
    func testWatcherStartsDisabled() {
        let watcher = IncidentWatcher(defaults: defaults)
        XCTAssertFalse(watcher.isEnabled, "S14 ships the toggle off by default")
    }

    @MainActor
    func testWatcherLoadsSeenIDsFromDefaults() {
        defaults.set(["old"], forKey: IncidentWatcher.seenKey)
        let watcher = IncidentWatcher(defaults: defaults)
        XCTAssertEqual(watcher.seenIDs, ["old"])
    }
}
