import XCTest
@testable import TransportCat

/// The tip jar's pure half (unit `support`): the product ids, the per-tier
/// wording, and the store's state machine driven by a fake store.
@MainActor
final class TipStoreTests: XCTestCase {
    // MARK: - Products

    func testTheThreeTiersAreTheAppStoreConsumableIds() {
        XCTAssertEqual(TipTier.allCases.map(\.productID), [
            "cat.transport.app.tip.small",
            "cat.transport.app.tip.medium",
            "cat.transport.app.tip.large",
        ])
        XCTAssertEqual(TipTier.productIDs, TipTier.allCases.map(\.productID))
    }

    func testEveryTierHasItsOwnWording() {
        let titles = TipTier.allCases.map(\.title)
        let noted = TipTier.allCases.map(\.note)
        XCTAssertEqual(Set(titles).count, titles.count)
        XCTAssertEqual(Set(noted).count, noted.count)
        for tier in TipTier.allCases {
            XCTAssertFalse(tier.title.isEmpty)
            XCTAssertFalse(tier.note.isEmpty)
            XCTAssertFalse(tier.thanks.isEmpty)
        }
    }

    /// One thank-you per tier, and the small one is a coffee.
    func testTheThankYouWordingIsPerTier() {
        XCTAssertEqual(TipTier.small.thanks, "Gràcies pel cafè!")
        XCTAssertEqual(TipTier.medium.thanks, "Gràcies pel doble!")
        XCTAssertEqual(TipTier.large.thanks, "Gràcies per la ronda!")
    }

    func testTheCaptionPromisesNothing() {
        XCTAssertEqual(TipCopy.sectionTitle, "Dona suport al desenvolupament")
        XCTAssertEqual(
            TipCopy.caption,
            "TransportCat és gratis i ho seguirà sent. Si vols donar suport al desenvolupament, ho agrairem molt — no desbloqueja res, és només suport."
        )
        XCTAssertEqual(TipCopy.purchaseFailed, "No s'ha pogut completar.")
    }

    // MARK: - State

    func testTheJarIsReadyOnlyWithSomethingToSell() {
        XCTAssertEqual(TipStore.state(for: []), .failed)
        XCTAssertEqual(TipStore.state(for: [TipProduct(id: TipTier.small.productID, displayPrice: "1,00 €")]), .ready)
    }

    func testALoadedJarShowsTheStorePrices() async {
        let purchasing = FakeTipPurchasing(products: [
            TipProduct(id: TipTier.small.productID, displayPrice: "1,00 €"),
            TipProduct(id: TipTier.medium.productID, displayPrice: "3,00 €"),
            TipProduct(id: TipTier.large.productID, displayPrice: "5,00 €"),
        ])
        let store = TipStore(purchasing: purchasing)

        XCTAssertEqual(store.state, .loading)
        await store.load()

        XCTAssertEqual(store.state, .ready)
        XCTAssertEqual(store.displayPrice(for: .small), "1,00 €")
        XCTAssertEqual(store.displayPrice(for: .large), "5,00 €")
        XCTAssertEqual(purchasing.loadedIDs, TipTier.productIDs)
    }

    func testAFailedOrEmptyLoadIsTheJarIsUnavailable() async {
        let failing = FakeTipPurchasing(loadError: FakeTipError())
        let store = TipStore(purchasing: failing)
        await store.load()
        XCTAssertEqual(store.state, .failed)

        let empty = FakeTipPurchasing(products: [])
        let other = TipStore(purchasing: empty)
        await other.load()
        XCTAssertEqual(other.state, .failed)
    }

    // MARK: - Purchase outcomes

    private func readyStore(_ outcome: TipPurchaseOutcome) async -> (TipStore, FakeTipPurchasing) {
        let purchasing = FakeTipPurchasing(
            products: TipTier.allCases.map { TipProduct(id: $0.productID, displayPrice: "1,00 €") },
            outcome: outcome
        )
        let store = TipStore(purchasing: purchasing)
        await store.load()
        return (store, purchasing)
    }

    func testBuyingThanksTheRiderPerTier() async {
        let (store, purchasing) = await readyStore(.purchased)

        await store.buy(.medium)

        XCTAssertEqual(store.purchase, .purchased(.medium))
        XCTAssertEqual(purchasing.purchasedIDs, [TipTier.medium.productID])
    }

    /// A completed purchase tells the Explora heart to stay away for good;
    /// every other outcome leaves the policy alone.
    func testOnlyABoughtTipSilencesTheBadge() async {
        var purchases = 0
        let purchasing = FakeTipPurchasing(
            products: [TipProduct(id: TipTier.small.productID, displayPrice: "1,00 €")],
            outcome: .purchased
        )
        let store = TipStore(purchasing: purchasing, onPurchased: { purchases += 1 })
        await store.load()

        await store.buy(.small)
        XCTAssertEqual(purchases, 1)

        for outcome in [TipPurchaseOutcome.cancelled, .pending, .failed] {
            let other = FakeTipPurchasing(
                products: [TipProduct(id: TipTier.small.productID, displayPrice: "1,00 €")],
                outcome: outcome
            )
            let otherStore = TipStore(purchasing: other, onPurchased: { purchases += 1 })
            await otherStore.load()
            await otherStore.buy(.small)
            XCTAssertEqual(purchases, 1, "\(outcome) must not silence the badge")
        }
    }

    /// Cancelling is not an error: no message, the jar back at rest, and the
    /// same tier can be tapped again.
    func testCancellingIsQuiet() async {
        let (store, _) = await readyStore(.cancelled)

        await store.buy(.small)

        XCTAssertEqual(store.purchase, .idle)
    }

    func testAPendingPurchaseSaysSo() async {
        let (store, _) = await readyStore(.pending)

        await store.buy(.large)

        XCTAssertEqual(store.purchase, .pending(.large))
    }

    func testAFailedPurchaseOffersTheRetry() async {
        let (store, _) = await readyStore(.failed)

        await store.buy(.small)

        XCTAssertEqual(store.purchase, .failed(.small))
    }

    func testAThrowingPurchaseIsAFailureNotACrash() async {
        let purchasing = FakeTipPurchasing(
            products: [TipProduct(id: TipTier.small.productID, displayPrice: "1,00 €")],
            purchaseError: FakeTipError()
        )
        let store = TipStore(purchasing: purchasing)
        await store.load()

        await store.buy(.small)

        XCTAssertEqual(store.purchase, .failed(.small))
    }

    func testAnUnloadedJarDoesNotBuy() async {
        let purchasing = FakeTipPurchasing(loadError: FakeTipError())
        let store = TipStore(purchasing: purchasing)
        await store.load()

        await store.buy(.small)

        XCTAssertEqual(store.purchase, .idle)
        XCTAssertTrue(purchasing.purchasedIDs.isEmpty)
    }
}

// MARK: - Fake

private struct FakeTipError: Error {}

private final class FakeTipPurchasing: TipPurchasing {
    private let products: [TipProduct]
    private let loadError: Error?
    private let outcome: TipPurchaseOutcome
    private let purchaseError: Error?
    private(set) var loadedIDs: [String] = []
    private(set) var purchasedIDs: [String] = []

    init(
        products: [TipProduct] = [],
        loadError: Error? = nil,
        outcome: TipPurchaseOutcome = .purchased,
        purchaseError: Error? = nil
    ) {
        self.products = products
        self.loadError = loadError
        self.outcome = outcome
        self.purchaseError = purchaseError
    }

    func loadProducts(for productIDs: [String]) async throws -> [TipProduct] {
        loadedIDs = productIDs
        if let loadError { throw loadError }
        return products
    }

    func purchase(id: String) async throws -> TipPurchaseOutcome {
        purchasedIDs.append(id)
        if let purchaseError { throw purchaseError }
        return outcome
    }
}
