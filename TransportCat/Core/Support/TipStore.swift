import Foundation
import Observation

/// The tip jar (unit `support`): three voluntary consumables that unlock
/// nothing. Apple-native on purpose — no external links, no unlocks, no Apple
/// Pay — so the app stays free and the support stays optional.
enum TipTier: String, CaseIterable, Identifiable {
    case small
    case medium
    case large

    var id: String { rawValue }

    /// App Store Connect product ids. The three exist there only after a human
    /// creates them; `Support.storekit` mirrors them for local testing.
    var productID: String { "cat.transport.app.tip.\(rawValue)" }

    /// Product ids in the order the jar shows them, with the smallest first.
    static var productIDs: [String] { allCases.map(\.productID) }

    var title: String {
        switch self {
        case .small: return String(localized: "Cafè")
        case .medium: return String(localized: "Doble")
        case .large: return String(localized: "Ronda")
        }
    }

    /// One line per price, so the rider knows what they are choosing between
    /// without a paragraph of marketing.
    var note: String {
        switch self {
        case .small: return String(localized: "Un cafè, com quan convides algú que t'ha estalviat una espera.")
        case .medium: return String(localized: "Un doble, per als dies en què la xarxa va de bòlit.")
        case .large: return String(localized: "Una ronda per a l'equip, si vols que això segueixi creixent.")
        }
    }

    /// The thank-you line after a completed purchase, one per tier.
    var thanks: String {
        switch self {
        case .small: return String(localized: "Gràcies pel cafè!")
        case .medium: return String(localized: "Gràcies pel doble!")
        case .large: return String(localized: "Gràcies per la ronda!")
        }
    }

    var systemImage: String {
        switch self {
        case .small: return "cup.and.saucer.fill"
        case .medium: return "cup.and.saucer.fill"
        case .large: return "person.3.fill"
        }
    }
}

/// The words around the jar, kept together so the two screens that show it —
/// Configuració and the introduction — read the same.
enum TipCopy {
    static let sectionTitle = String(localized: "Dona suport al desenvolupament")
    static let caption = String(
        localized: "TransportCat és gratis i ho seguirà sent. Si vols donar suport al desenvolupament, ho agrairem molt — no desbloqueja res, és només suport."
    )
    static let loading = String(localized: "Carregant els imports…")
    static let loadFailed = String(localized: "No s'han pogut carregar els imports. Torna-ho a provar.")
    static let purchaseFailed = String(localized: "No s'ha pogut completar.")
    static let pending = String(localized: "S'està processant el pagament. Ho rebràs quan s'aprovi.")
    static let retry = String(localized: "Torna-ho a provar")
}

/// One purchasable tip as the jar needs it: the id and the price the store
/// shows. `Product` itself never crosses the seam, so the store's state machine
/// is testable without StoreKit.
struct TipProduct: Identifiable, Equatable {
    let id: String
    let displayPrice: String
}

/// How a purchase ended, mapped verbatim from `Product.PurchaseResult` by the
/// StoreKit adapter.
enum TipPurchaseOutcome: Equatable {
    /// `.success` with a verified transaction; the transaction is finished.
    case purchased
    /// `.userCancelled`: the rider closed the sheet. Not an error, not a word.
    case cancelled
    /// `.pending`, e.g. Ask to Buy: waiting on someone else.
    case pending
    /// `.success` with an unverified transaction, or no product to buy.
    case failed
}

/// The StoreKit calls the jar makes, behind a protocol so tests drive them.
protocol TipPurchasing {
    /// The three products, in whatever order the store answers. Throws only for
    /// a failed store request.
    func loadProducts(for productIDs: [String]) async throws -> [TipProduct]
    /// Buys one product and reports how it ended.
    func purchase(id: String) async throws -> TipPurchaseOutcome
}

/// The jar's state, out of the view: what to show, and what the last tap did.
@MainActor
@Observable
final class TipStore {
    enum State: Equatable {
        case loading
        case ready
        case failed
    }

    enum Purchase: Equatable {
        case idle
        case purchasing(TipTier)
        case purchased(TipTier)
        case pending(TipTier)
        case failed(TipTier)
    }

    private(set) var state: State = .loading
    private(set) var products: [TipProduct] = []
    private(set) var purchase: Purchase = .idle

    private let purchasing: TipPurchasing
    /// Called once per completed purchase, so the Explora heart can go quiet
    /// for good (unit `support`). No-op by default: the store's tests never
    /// touch the app's `UserDefaults`.
    private let onPurchased: () -> Void

    init(
        purchasing: TipPurchasing = StoreKitTipPurchasing(),
        onPurchased: @escaping () -> Void = {}
    ) {
        self.purchasing = purchasing
        self.onPurchased = onPurchased
    }

    /// A jar with nothing to sell cannot be shown as ready: `Product.products`
    /// answers an empty list both when the ids do not exist and when the store
    /// is unreachable, and either way there is nothing to tap.
    static func state(for products: [TipProduct]) -> State {
        products.isEmpty ? .failed : .ready
    }

    /// The price the store reports for a tier, or `nil` while it has none.
    func displayPrice(for tier: TipTier) -> String? {
        products.first { $0.id == tier.productID }?.displayPrice
    }

    /// Asks the store for the three products. Called once per screen visit.
    func load() async {
        state = .loading
        do {
            products = try await purchasing.loadProducts(for: TipTier.productIDs)
            state = Self.state(for: products)
        } catch {
            products = []
            state = .failed
        }
    }

    /// Buys one tier. Cancelling returns the jar to rest with no message, and a
    /// failure leaves the tier's row ready for a second try.
    func buy(_ tier: TipTier) async {
        guard state == .ready else { return }
        if case .purchasing = purchase { return }
        purchase = .purchasing(tier)
        do {
            switch try await purchasing.purchase(id: tier.productID) {
            case .purchased:
                purchase = .purchased(tier)
                onPurchased()
            case .cancelled: purchase = .idle
            case .pending: purchase = .pending(tier)
            case .failed: purchase = .failed(tier)
            }
        } catch {
            purchase = .failed(tier)
        }
    }
}
