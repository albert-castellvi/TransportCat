import XCTest
@testable import TransportCat

/// The Explora heart's two halves (unit `support`): the pure visibility rule
/// and the store that persists the three dates it reads.
final class TipBadgePolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 24 * 60 * 60

    // MARK: - Policy boundaries

    func testNoRecordedFirstLaunchIsNeverVisible() {
        XCTAssertFalse(TipBadgePolicy.isVisible(TipBadgeDates(), now: now))
    }

    /// Day 0 through day 6 are quiet; the seventh day is the first one that
    /// can show the icon.
    func testTheIconAppearsExactlyOnDaySeven() {
        XCTAssertFalse(TipBadgePolicy.isVisible(
            TipBadgeDates(firstLaunch: now - 7 * day + 1),
            now: now
        ))
        XCTAssertTrue(TipBadgePolicy.isVisible(
            TipBadgeDates(firstLaunch: now - 7 * day),
            now: now
        ))
        XCTAssertTrue(TipBadgePolicy.isVisible(
            TipBadgeDates(firstLaunch: now - 8 * day),
            now: now
        ))
    }

    /// Once shown, it stays away for fourteen days: one second before the
    /// boundary is quiet, the boundary itself is not.
    func testItStaysQuietForFourteenDaysAfterBeingShown() {
        let firstLaunch = now - 30 * day
        XCTAssertFalse(TipBadgePolicy.isVisible(
            TipBadgeDates(firstLaunch: firstLaunch, lastShown: now - 14 * day + 1),
            now: now
        ))
        XCTAssertTrue(TipBadgePolicy.isVisible(
            TipBadgeDates(firstLaunch: firstLaunch, lastShown: now - 14 * day),
            now: now
        ))
    }

    /// A bought tip silences the icon for good, not for a month: the same date
    /// still hides it a year later.
    func testATipSilencesItPermanently() {
        XCTAssertFalse(TipBadgePolicy.isVisible(
            TipBadgeDates(firstLaunch: now - 60 * day, lastTip: now - day),
            now: now
        ))
        XCTAssertFalse(TipBadgePolicy.isVisible(
            TipBadgeDates(firstLaunch: now - 400 * day, lastTip: now - 400 * day),
            now: now
        ))
    }

    func testTheProbeVocabularyPinsEveryScenario() {
        let cases: [(String, Bool)] = [
            ("fresh", false),
            ("eligible", true),
            ("recent", false),
            ("tipped", false),
        ]
        for (probe, expected) in cases {
            let dates = TipBadgeStore.probeDates(probe, now: now)
            XCTAssertNotNil(dates, probe)
            XCTAssertEqual(dates.map { TipBadgePolicy.isVisible($0, now: now) }, expected, probe)
        }
        XCTAssertNil(TipBadgeStore.probeDates("something-else", now: now))
    }
}

/// The store side: the first launch is written once, a shown day is recorded,
/// and a tip closes the door. Throwaway suite, so the app's domain is never
/// touched.
final class TipBadgeStoreTests: XCTestCase {
    private let suiteName = "TipBadgeStoreTests"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 24 * 60 * 60

    private func makeDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        UserDefaults.standard.removeObject(forKey: TipBadgeStore.probeKey)
        super.tearDown()
    }

    func testAFreshInstallRecordsTheFirstLaunchAndStaysHidden() {
        let defaults = makeDefaults()

        let store = TipBadgeStore(defaults: defaults, now: now)

        XCTAssertEqual(store.dates.firstLaunch, now)
        XCTAssertFalse(store.shouldShow(now: now))
        XCTAssertEqual(defaults.object(forKey: TipBadgeStore.firstLaunchKey) as? Date, now)
        XCTAssertNil(defaults.object(forKey: TipBadgeStore.lastShownKey))
    }

    func testAnExistingFirstLaunchIsNeverOverwritten() {
        let defaults = makeDefaults()
        let earlier = now - 100 * day
        defaults.set(earlier, forKey: TipBadgeStore.firstLaunchKey)

        let store = TipBadgeStore(defaults: defaults, now: now)

        XCTAssertEqual(store.dates.firstLaunch, earlier)
        XCTAssertEqual(defaults.object(forKey: TipBadgeStore.firstLaunchKey) as? Date, earlier)
    }

    func testDayEightShowsOnceAndRecordsTheDay() {
        let defaults = makeDefaults()
        defaults.set(now - 8 * day, forKey: TipBadgeStore.firstLaunchKey)
        let store = TipBadgeStore(defaults: defaults, now: now)

        XCTAssertTrue(store.shouldShow(now: now))
        XCTAssertEqual(defaults.object(forKey: TipBadgeStore.lastShownKey) as? Date, now)
        // Within the same run the icon stays, so the toolbar does not flicker
        // when the tab is re-entered.
        XCTAssertTrue(store.shouldShow(now: now))
        // The next launch already sees yesterday's appearance and goes quiet.
        let relaunched = TipBadgeStore(defaults: defaults, now: now)
        XCTAssertFalse(relaunched.shouldShow(now: now))
    }

    func testItComesBackAfterFourteenQuietDays() {
        let defaults = makeDefaults()
        defaults.set(now - 30 * day, forKey: TipBadgeStore.firstLaunchKey)
        defaults.set(now - 14 * day, forKey: TipBadgeStore.lastShownKey)

        let store = TipBadgeStore(defaults: defaults, now: now)

        XCTAssertTrue(store.shouldShow(now: now))
        XCTAssertEqual(defaults.object(forKey: TipBadgeStore.lastShownKey) as? Date, now)
    }

    func testATipSilencesItForGood() {
        let defaults = makeDefaults()
        defaults.set(now - 60 * day, forKey: TipBadgeStore.firstLaunchKey)
        let store = TipBadgeStore(defaults: defaults, now: now)

        store.recordTip(now: now)

        XCTAssertFalse(store.shouldShow(now: now))
        XCTAssertEqual(defaults.object(forKey: TipBadgeStore.lastTipKey) as? Date, now)
        // A year later, still silent.
        let muchLater = now + 400 * day
        let relaunched = TipBadgeStore(defaults: defaults, now: muchLater)
        XCTAssertFalse(relaunched.shouldShow(now: muchLater))
    }

    /// The debug launch argument answers without overwriting what the rider's
    /// own dates say: the tour proves the policy, not a second store.
    func testAProbeAnswersWithoutPersisting() {
        let defaults = makeDefaults()
        UserDefaults.standard.set("eligible", forKey: TipBadgeStore.probeKey)

        let store = TipBadgeStore(defaults: defaults, now: now)

        XCTAssertTrue(store.shouldShow(now: now))
        XCTAssertNil(defaults.object(forKey: TipBadgeStore.firstLaunchKey))
        XCTAssertNil(defaults.object(forKey: TipBadgeStore.lastShownKey))
        XCTAssertNil(defaults.object(forKey: TipBadgeStore.lastTipKey))

        let fresh = makeDefaults()
        UserDefaults.standard.set("fresh", forKey: TipBadgeStore.probeKey)
        XCTAssertFalse(TipBadgeStore(defaults: fresh, now: now).shouldShow(now: now))
    }
}
