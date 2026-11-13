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

    /// The tour is the nine screens the app already had plus "Sempre
    /// millorant": ten pages that explain, and the permissions page — the only
    /// one with buttons of its own — still closes it right before "Comença".
    func testTheTourIsInformationalAndClosesOnPermissions() {
        XCTAssertEqual(OnboardingPage.all.count, 10)
        XCTAssertEqual(OnboardingPage.all.first?.id, "welcome")
        XCTAssertEqual(OnboardingPage.all.suffix(2).map(\.id), ["improving", "permissions"])
        XCTAssertEqual(OnboardingPage.all.filter(\.requestsPermissions).count, 1)
        XCTAssertTrue(OnboardingPage.all.last?.requestsPermissions ?? false)
    }

    /// "Sempre millorant" is words only: four bullets that say where the data
    /// comes from, where to write and where to support. It embeds no form and
    /// no jar — the tour never asks the rider for anything.
    func testTheAlwaysImprovingPageIsWordsOnly() {
        let page = OnboardingPage.all.first { $0.id == "improving" }
        XCTAssertEqual(page?.title, "Sempre millorant")
        XCTAssertEqual(page?.artwork, .improving)
        XCTAssertEqual(page?.bullets.map(\.text), [
            "L'app millora amb les dades de TMB, FGC i Renfe, i s'afina amb l'ús que en fem tots.",
            "Si hi ha res que no va o que hi falta, escriu-nos des de Configuració › Suport i millores.",
            "Si l'app et serveix bé, pots donar-li suport des de Configuració › Dona suport al desenvolupament.",
            "És gratis, sense anuncis i sense compte.",
        ])
        XCTAssertEqual(page?.requestsPermissions, false)
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
