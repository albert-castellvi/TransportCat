import StoreKit

/// StoreKit 2 behind `TipPurchasing` (unit `support`).
///
/// Only this file names StoreKit: the jar's state machine and its wording stay
/// pure, so `TipStoreTests` never touches the store.
///
/// Signatures checked against the iOS 26.2 simulator SDK
/// (`StoreKit.swiftmodule/arm64-apple-ios-simulator.swiftinterface`):
/// `Product.products(for:)` (line 1715), `Product.displayPrice` (1681),
/// `MainActor func purchase(options:) async throws -> Product.PurchaseResult`
/// (1649), `PurchaseResult.success(VerificationResult<Transaction>)` (1627-1631)
/// and `Transaction.finish() async` (1381).
struct StoreKitTipPurchasing: TipPurchasing {
    func loadProducts(for productIDs: [String]) async throws -> [TipProduct] {
        let products = try await Product.products(for: productIDs)
        return products.map { TipProduct(id: $0.id, displayPrice: $0.displayPrice) }
    }

    func purchase(id: String) async throws -> TipPurchaseOutcome {
        // The jar showed a price for this id, so an empty answer here means the
        // product disappeared between the two calls.
        guard let product = try await Product.products(for: [id]).first else { return .failed }
        let result = try await product.purchase()
        switch result {
        case .success(let verification):
            // A consumable is spent the moment it is bought: finish it so the
            // store stops re-delivering it, and only thank the rider when the
            // signature is verified.
            guard case .verified(let transaction) = verification else { return .failed }
            await transaction.finish()
            return .purchased
        case .userCancelled:
            return .cancelled
        case .pending:
            return .pending
        @unknown default:
            return .failed
        }
    }
}
