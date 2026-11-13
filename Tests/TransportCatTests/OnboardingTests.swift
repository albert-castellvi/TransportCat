import XCTest
@testable import TransportCat

/// The introduction's page list and its first-run flag (unit `onboarding`).
/// The pages are plain data and the flag is a `UserDefaults` key, so both are
/// checked here instead of through the screen.
final class OnboardingTests: XCTestCase {
    private let suiteName = "OnboardingTests"

    private func makeDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - Pages

    func testEveryPageHasATitleAndAtLeastThreeBullets() {
        XCTAssertFalse(OnboardingPage.all.isEmpty)
        for page in OnboardingPage.all {
            XCTAssertFalse(page.title.isEmpty, "page \(page.id) has no title")
            XCTAssertGreaterThanOrEqual(page.bullets.count, 3, "page \(page.id) has fewer than 3 bullets")
            XCTAssertLessThanOrEqual(page.bullets.count, 5, "page \(page.id) has more than 5 bullets")
        }
    }

    func testEveryBulletHasAnIconAndASentence() {
        for page in OnboardingPage.all {
            for bullet in page.bullets {
                XCTAssertFalse(bullet.systemImage.isEmpty, "bullet of \(page.id) has no icon")
                XCTAssertFalse(bullet.text.isEmpty, "bullet of \(page.id) has no text")
            }
        }
    }

    func testPageIdentifiersAreUnique() {
        let ids = OnboardingPage.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    /// The tour opens on what the app is, and the permissions — the only page
    /// with buttons of its own — close it, right before "Comença".
    func testTheTourStartsOnTheWelcomePageAndEndsOnPermissions() {
        XCTAssertEqual(OnboardingPage.all.first?.id, "welcome")
        XCTAssertEqual(OnboardingPage.all.last?.id, "permissions")
        XCTAssertEqual(OnboardingPage.all.filter(\.requestsPermissions).count, 1)
        XCTAssertTrue(OnboardingPage.all.last?.requestsPermissions ?? false)
    }

    // MARK: - Page arithmetic

    func testNextStopsAtTheLastPage() {
        let count = OnboardingPage.all.count
        XCTAssertEqual(OnboardingFlow.next(after: 0, count: count), 1)
        XCTAssertEqual(OnboardingFlow.next(after: count - 2, count: count), count - 1)
        // Tapping "Continua" again on the last page must not run past it.
        XCTAssertEqual(OnboardingFlow.next(after: count - 1, count: count), count - 1)
    }

    func testIsLastOnlyForTheLastPage() {
        let count = OnboardingPage.all.count
        XCTAssertFalse(OnboardingFlow.isLast(0, count: count))
        XCTAssertTrue(OnboardingFlow.isLast(count - 1, count: count))
        XCTAssertEqual(OnboardingFlow.lastIndex(count: count), count - 1)
    }

    func testAnEmptyPageListNeverAnswersANegativeIndex() {
        XCTAssertEqual(OnboardingFlow.lastIndex(count: 0), 0)
        XCTAssertTrue(OnboardingFlow.isLast(0, count: 0))
        XCTAssertEqual(OnboardingFlow.next(after: 0, count: 0), 0)
    }

    // MARK: - Flag

    func testTheFlagStartsHiddenAndComesBackWhenReopened() {
        let defaults = makeDefaults()

        XCTAssertFalse(OnboardingFlow.hasSeen(in: defaults))
        XCTAssertTrue(OnboardingFlow.isPresented(hasSeen: OnboardingFlow.hasSeen(in: defaults)))

        // Skipping and finishing both land here.
        OnboardingFlow.markSeen(in: defaults)
        XCTAssertTrue(OnboardingFlow.hasSeen(in: defaults))
        XCTAssertFalse(OnboardingFlow.isPresented(hasSeen: OnboardingFlow.hasSeen(in: defaults)))

        // Configuració's "Torna a veure la introducció".
        OnboardingFlow.reopen(in: defaults)
        XCTAssertFalse(OnboardingFlow.hasSeen(in: defaults))
        XCTAssertTrue(OnboardingFlow.isPresented(hasSeen: OnboardingFlow.hasSeen(in: defaults)))
    }
}
