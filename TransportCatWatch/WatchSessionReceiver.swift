import Foundation
import Observation
import WatchConnectivity

/// Receives the phone's favorite places through the WatchConnectivity
/// application context (spec S22, review W16).
///
/// The context is read twice: from `receivedApplicationContext` right at
/// launch, because the phone may not be reachable yet, and from every update
/// after that. The payload is a whole list with the moment it was encoded
/// (`WatchFavoritesPayload`), which is what makes a removed place disappear and
/// the phone's order win.
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
        apply(WatchFavoritesPayload.from(context: session.receivedApplicationContext))
        session.activate()
    }

    private func apply(_ payload: WatchFavoritesPayload?) {
        guard let payload else { return }
        store.replace(with: payload)
    }

    // MARK: - WCSessionDelegate

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        let activated = activationState == .activated
        let payload = WatchFavoritesPayload.from(context: session.receivedApplicationContext)
        Task { @MainActor in
            self.isActivated = activated
            // #79: a failed activation must release the single retry entry
            // point, so the next foreground can call `activate()` again.
            if !activated { self.isActivating = false }
            self.apply(payload)
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        let payload = WatchFavoritesPayload.from(context: applicationContext)
        Task { @MainActor in self.apply(payload) }
    }
}
