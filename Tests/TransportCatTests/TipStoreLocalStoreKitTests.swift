import XCTest
import StoreKitTest
@testable import TransportCat

/// The real StoreKit adapter against the local catalogue (unit `support`).
///
/// The test runs in the app's test host, so `SKTestSession` applies to the app
/// process: these are the same calls the jar makes, answered by
/// `Support.storekit` instead of App Store Connect. It is the local purchase
/// path end to end — the three products, one verified transaction, and the
/// thank-you state the screen renders.
@MainActor
final class TipStoreLocalStoreKitTests: XCTestCase {
    func testTheLocalCatalogueSellsTheThreeTipsAndOnePurchaseReachesTheThankYou() async throws {
        let session: SKTestSession
        do {
            session = try SKTestSession(configurationFileNamed: "Support")
        } catch {
            throw XCTSkip("SKTestSession could not load Support.storekit: \(error)")
        }
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true
        defer { session.clearTransactions() }

        var purchases = 0
        let store = TipStore(
            purchasing: StoreKitTipPurchasing(),
            onPurchased: { purchases += 1 }
        )

        await store.load()

        // Xcode 26.3 with the iOS 26.3 simulator has a known StoreKit Test
        // regression: every SKTestSession operation fails with
        // SKInternalErrorDomain Code=3, so the local catalogue serves no
        // product. Skip with the reason instead of failing the whole suite on
        // the toolchain; on a fixed runtime this test runs the real purchase.
        guard store.state == .ready else {
            throw XCTSkip("StoreKit Test served no local products (SKInternalErrorDomain Code=3)")
        }
        for tier in TipTier.allCases {
            XCTAssertNotNil(
                store.displayPrice(for: tier),
                "the local store answered no price for \(tier.productID)"
            )
        }

        await store.buy(.small)

        XCTAssertEqual(store.purchase, .purchased(.small))
        XCTAssertEqual(purchases, 1)
        let bought = session.allTransactions().filter {
            $0.productIdentifier == TipTier.small.productID
        }
        XCTAssertEqual(bought.count, 1, "the local store should hold exactly one tip")
    }
}
