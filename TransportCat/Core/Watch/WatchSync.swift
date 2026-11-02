import Foundation

#if canImport(WatchConnectivity)
import WatchConnectivity

/// Pushes the favorite places to the Apple Watch (spec S22).
///
/// The watch is a separate process and cannot read the phone's
/// `UserDefaults`, so the phone mirrors the favorites into the
/// WatchConnectivity *application context*. That context is a single
/// replaceable slot: the watch always gets the latest list, even when it was
/// not reachable when a favorite changed, and the payload survives relaunches
/// on both sides. There is no App Group and no push backend.
@MainActor
final class WatchSync: NSObject, WCSessionDelegate {
    static let shared = WatchSync()

    /// Application-context key holding the JSON of `[Place]`; the watch side
    /// (`WatchSessionReceiver`) reads the same key.
    static let favoritesKey = "favorites"

    /// Encoded favorites waiting for the session to activate, and the last
    /// payload the session accepted, so an unchanged list is never re-sent.
    private var pendingData: Data?
    private var sentData: Data?
    private var isActivating = false

    /// Activates the session and pushes the current favorites at launch.
    func start(places: [Place]) {
        activate()
        sync(places)
    }

    /// Pushes `places` to the watch.
    func sync(_ places: [Place]) {
        guard WCSession.isSupported(), let data = try? JSONEncoder().encode(places) else { return }
        pendingData = data
        flush()
    }

    private func activate() {
        guard WCSession.isSupported(), !isActivating else { return }
        isActivating = true
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    /// Sends the pending payload once the session is active; a launch-time
    /// sync runs before that, so it waits here instead of being dropped.
    private func flush() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated, let data = pendingData else { return }
        pendingData = nil
        guard data != sentData else { return }
        do {
            try session.updateApplicationContext([Self.favoritesKey: data])
            sentData = data
        } catch {
            // Best effort: the next favorites change retries the whole list.
        }
    }

    // MARK: - WCSessionDelegate

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor in self.flush() }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // The paired watch changed: reactivate so the next flush can send.
        WCSession.default.activate()
    }
}
#endif
