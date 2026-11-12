import Foundation
import Observation
import WatchConnectivity

/// Receives the phone's favorite places through the WatchConnectivity
/// application context (spec S22).
///
/// The context is read twice: from `receivedApplicationContext` right at
/// launch, because the phone may not be reachable yet, and from every update
/// after that. Decoding lives in `WatchPayload`, which is pure and tested.
@MainActor
@Observable
final class WatchSessionReceiver: NSObject, WCSessionDelegate {
    static let shared = WatchSessionReceiver()

    private(set) var isActivated = false

    private let store: WatchFavoritesStore
    private var isActivating = false

    init(store: WatchFavoritesStore = .shared) {
        self.store = store
        super.init()
    }

    /// Activates the session and loads whatever the phone already pushed.
    func activate() {
        guard WCSession.isSupported(), !isActivating else { return }
        isActivating = true
        let session = WCSession.default
        session.delegate = self
        apply(WatchPayload.places(from: session.receivedApplicationContext))
        session.activate()
    }

    private func apply(_ places: [Place]?) {
        guard let places else { return }
        store.replace(with: places)
    }

    // MARK: - WCSessionDelegate

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        let activated = activationState == .activated
        let places = WatchPayload.places(from: session.receivedApplicationContext)
        Task { @MainActor in
            self.isActivated = activated
            // #79: a failed activation must release the single retry entry
            // point, so the next foreground can call `activate()` again.
            if !activated { self.isActivating = false }
            self.apply(places)
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        let places = WatchPayload.places(from: applicationContext)
        Task { @MainActor in self.apply(places) }
    }
}
