import Foundation
import XCTest
@testable import TransportCat

/// Tests for the pure state of the v2 status capsule (spec S2): the one rule
/// that decides what the capsule shows for a feed's freshness values and the
/// device's connectivity.
///
/// Times are built from a fixed `now` exactly like `FreshnessTests`, so the
/// wording asserted here never depends on the wall clock. The offline case
/// wins over every freshness level, because the capsule's job when the device
/// has no network path is to explain that what is on screen comes from saved
/// data and the theoretical timetable (the wording of the removed offline
/// banner, spec S21 of the previous design).
final class StatusCapsuleStateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func state(
        isOnline: Bool = true,
        updatedAfter seconds: TimeInterval? = 0,
        lastAttemptFailed: Bool = false,
        feedEmpty: Bool = false,
        theoretical: Bool = false
    ) -> StatusCapsuleState {
        let updatedAt = seconds.map { now.addingTimeInterval(-$0) }
        return StatusCapsule.make(
            isOnline: isOnline,
            updatedAt: updatedAt,
            lastAttemptFailed: lastAttemptFailed,
            feedEmpty: feedEmpty,
            theoretical: theoretical,
            now: now
        )
    }

    // MARK: - Offline

    func testOfflineShowsWifiOffIconAndSavedDataWording() {
        let offline = state(isOnline: false)
        XCTAssertEqual(offline.icon, .wifiOff)
        XCTAssertEqual(offline.label, "Sense connexió")
        XCTAssertEqual(offline.detail, "dades desades i horaris teòrics")
    }

    func testOfflineWinsOverEveryFreshnessLevel() {
        XCTAssertEqual(
            state(isOnline: false, theoretical: true).icon, .wifiOff
        )
        XCTAssertEqual(
            state(isOnline: false, feedEmpty: true).icon, .wifiOff
        )
        // Even a feed that never answered: offline still names the reason.
        XCTAssertEqual(
            state(isOnline: false, updatedAfter: nil).label, "Sense connexió"
        )
    }

    // MARK: - Live levels (the `Freshness` wording, unchanged)

    func testFreshUpdateIsLiveWithItsAgeAsDetail() {
        let live = state(updatedAfter: 8)
        XCTAssertEqual(live.icon, .dot(.live))
        XCTAssertEqual(live.label, "En directe")
        XCTAssertEqual(live.detail, "fa 8 s")
    }

    func testDelayedUpdateKeepsTheFreshnessWording() {
        let delayed = state(updatedAfter: 45)
        XCTAssertEqual(delayed.icon, .dot(.delayed))
        XCTAssertEqual(delayed.label, "Amb retard")
        XCTAssertEqual(delayed.detail, "fa 45 s")
    }

    func testFailedAttemptDowngradesLiveToDelayed() {
        let delayed = state(updatedAfter: 5, lastAttemptFailed: true)
        XCTAssertEqual(delayed.icon, .dot(.delayed))
        XCTAssertEqual(delayed.label, "Amb retard")
    }

    func testStaleUpdateKeepsTheFreshnessWording() {
        let stale = state(updatedAfter: 120)
        XCTAssertEqual(stale.icon, .dot(.stale))
        XCTAssertEqual(stale.label, "Dades antigues")
        XCTAssertEqual(stale.detail, "fa 2 min")
    }

    // MARK: - No data yet

    func testNoUpdateEverIsUnavailableWithoutDetail() {
        let unavailable = state(updatedAfter: nil)
        XCTAssertEqual(unavailable.icon, .dot(.unavailable))
        XCTAssertEqual(unavailable.label, "Sense dades")
        XCTAssertEqual(unavailable.detail, "")
    }

    // MARK: - Line without a live feed

    func testEmptyFeedStatesTheRealtimeWording() {
        let empty = state(feedEmpty: true)
        XCTAssertEqual(empty.icon, .dot(.unavailable))
        XCTAssertEqual(empty.label, "Sense dades en temps real")
        XCTAssertEqual(empty.detail, "")
    }

    // MARK: - Theoretical timetable

    func testTheoreticalFeedIsNamedInsteadOfCountingAge() {
        let theoretical = state(theoretical: true, updatedAfter: 8)
        XCTAssertEqual(theoretical.icon, .dot(.theoretical))
        XCTAssertEqual(theoretical.label, "Horari teòric")
        XCTAssertEqual(theoretical.detail, "")
    }

    func testTheoreticalWinsOverEmptyFeedLikeTheFreshnessChipDid() {
        let both = state(theoretical: true, feedEmpty: true)
        XCTAssertEqual(both.icon, .dot(.theoretical))
        XCTAssertEqual(both.label, "Horari teòric")
    }
}
