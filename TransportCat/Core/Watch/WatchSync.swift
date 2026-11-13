import Foundation

#if canImport(WatchConnectivity)
import WatchConnectivity

/// Pushes the favorite places to the Apple Watch (spec S22, review W16).
///
/// The watch is a separate process and cannot read the phone's `UserDefaults`,
/// so the phone mirrors the favorites into the WatchConnectivity *application
/// context*. That context is a single replaceable slot: the watch always gets the
/// latest list, even when it was not reachable when a favorite changed, and the
/// payload survives relaunches on both sides. There is no App Group and no push
/// backend.
///
/// The list travels whole and dated (`WatchFavoritesPayload`), which is what lets
/// the watch drop a place that was unstared here, keep the order the rider set
/// in Explora, and tell "never synced" from "no favorites".
@MainActor
final class WatchSync: NSObject, WCSessionDelegate {
    static let shared = WatchSync()

    /// Application-context key holding the payload; the watch side reads the
    /// same one through `WatchFavoritesPayload.from(context:)`.
    static let contextKey = WatchFavoritesPayload.contextKey

    /// Payload waiting for the session to activate, and the last one the session
    /// accepted, so an unchanged list is never re-sent.
    private var pendingPayload: WatchFavoritesPayload?
    private var sentData: Data?
    private var isActivating = false

    /// Activates the session and pushes the current favorites at launch.
    func start(places: [Place]) {
        activate()
        sync(places)
    }

    /// Pushes `places` to the watch.
    func sync(_ places: [Place]) {
        guard WCSession.isSupported() else { return }
        pendingPayload = WatchFavoritesPayload(places: places)
        // A launch-time activation that failed is retried by the next change.
        activate()
        flush()
    }

    private func activate() {
        guard WCSession.isSupported(), !isActivating else { return }
        isActivating = true
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    /// Sends the pending payload once the session is active; a launch-time sync
    /// runs before that, so it waits here instead of being dropped.
    private func flush() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated, let payload = pendingPayload else { return }
        guard let data = payload.encoded() else { return }
        guard data != sentData else {
            pendingPayload = nil
            return
        }
        let context = payload.applicationContext
        guard !context.isEmpty else { return }
        do {
            try session.updateApplicationContext(context)
            sentData = data
            pendingPayload = nil
        } catch {
            // Keep the payload: the next favorites change or the next activation
            // retries the whole list.
        }
    }

    // MARK: - WCSessionDelegate

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor in
            if activationState != .activated { self.isActivating = false }
            self.flush()
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // The paired watch changed: reactivate so the next flush can send.
        WCSession.default.activate()
    }
}
#endif
