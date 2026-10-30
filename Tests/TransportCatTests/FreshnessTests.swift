import XCTest
@testable import TransportCat

/// Tests for the freshness model (spec S2): `Freshness.level`, its thresholds
/// and the Catalan age wording.
///
/// Ages are built from a fixed `now` and a `lastUpdate` offset from it, so the
/// tests never depend on the wall clock.
final class FreshnessTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func level(after seconds: TimeInterval?, lastAttemptFailed: Bool = false) -> DataFreshness {
        let lastUpdate = seconds.map { now.addingTimeInterval(-$0) }
        return Freshness.level(
            lastUpdate: lastUpdate,
            now: now,
            lastAttemptFailed: lastAttemptFailed
        )
    }

    private func ageText(_ seconds: TimeInterval) -> String {
        Freshness.ageText(since: now.addingTimeInterval(-seconds), now: now)
    }

    // MARK: - Thresholds

    func testThresholdsAreThirtyAndNinetySeconds() {
        XCTAssertEqual(Freshness.delayedAfter, 30)
        XCTAssertEqual(Freshness.staleAfter, 90)
    }

    func testNoUpdateEverIsUnavailable() {
        XCTAssertEqual(level(after: nil), .unavailable)
    }

    func testJustUpdatedIsLive() {
        XCTAssertEqual(level(after: 0), .live)
    }

    func testJustUnderTheDelayedThresholdIsLive() {
        XCTAssertEqual(level(after: 29.9), .live)
    }

    func testExactlyAtTheDelayedThresholdIsDelayed() {
        XCTAssertEqual(level(after: 30), .delayed)
    }

    func testJustUnderTheStaleThresholdIsDelayed() {
        XCTAssertEqual(level(after: 89.9), .delayed)
    }

    func testExactlyAtTheStaleThresholdIsStale() {
        XCTAssertEqual(level(after: 90), .stale)
    }

    func testLongAfterTheStaleThresholdIsStale() {
        XCTAssertEqual(level(after: 3_600), .stale)
    }

    // MARK: - Failed attempt

    func testFailedAttemptAfterALiveUpdateDowngradesToDelayed() {
        XCTAssertEqual(level(after: 0, lastAttemptFailed: true), .delayed)
        XCTAssertEqual(level(after: 20, lastAttemptFailed: true), .delayed)
    }

    func testFailedAttemptLeavesStaleUnchanged() {
        XCTAssertEqual(level(after: 120, lastAttemptFailed: true), .stale)
    }

    func testFailedAttemptLeavesUnavailableUnchanged() {
        XCTAssertEqual(level(after: nil, lastAttemptFailed: true), .unavailable)
    }

    func testFailedAttemptNeverUpgradesAnAlreadyDelayedLevel() {
        XCTAssertEqual(level(after: 45, lastAttemptFailed: true), .delayed)
    }

    // MARK: - Age wording

    func testAgeTextUnderFiveSecondsSaysJustNow() {
        XCTAssertEqual(ageText(0), "ara mateix")
        XCTAssertEqual(ageText(4.9), "ara mateix")
    }

    func testAgeTextFromFiveSecondsCountsSeconds() {
        XCTAssertEqual(ageText(5), "fa 5 s")
    }

    func testAgeTextTruncatesSecondsBelowOneMinute() {
        XCTAssertEqual(ageText(59), "fa 59 s")
        XCTAssertEqual(ageText(59.9), "fa 59 s")
    }

    func testAgeTextSwitchesToMinutesAtSixtySeconds() {
        XCTAssertEqual(ageText(60), "fa 1 min")
        XCTAssertEqual(ageText(119), "fa 1 min")
    }

    func testAgeTextCountsWholeMinutes() {
        XCTAssertEqual(ageText(150), "fa 2 min")
    }

    func testAgeTextSwitchesToHoursAtOneHour() {
        XCTAssertEqual(ageText(3_599), "fa 59 min")
        XCTAssertEqual(ageText(3_600), "fa 1 h")
        XCTAssertEqual(ageText(7_300), "fa 2 h")
    }

    func testNegativeAgeReadsAsJustNow() {
        XCTAssertEqual(Freshness.ageText(since: now.addingTimeInterval(30), now: now), "ara mateix")
    }
}
