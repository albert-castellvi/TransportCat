import Foundation
import Observation

#if canImport(Network)
import Network
#endif

/// Whether the device currently has a usable network path (spec S21).
///
/// One `NWPathMonitor` on a private queue feeds `isOnline`, published on the
/// main actor, so the offline banner and the theoretical-fleet fallback share
/// a single source instead of each store guessing from failed requests. The
/// value starts `true`: the monitor's first path update arrives in
/// milliseconds, and until then the app behaves exactly as it did before this
/// class existed — no banner, no premature fallback.
@MainActor
@Observable
final class ConnectivityMonitor {
    static let shared = ConnectivityMonitor()

    /// True while the system reports a satisfied path.
    private(set) var isOnline = true

    #if canImport(Network)
    private let monitor = NWPathMonitor()
    /// Dedicated serial queue: the callback never runs on the main actor.
    private let queue = DispatchQueue(label: "cat.transport.app.connectivity")
    #endif

    @ObservationIgnored private var started = false

    /// Attaches the path handler and starts monitoring. Idempotent, so every
    /// screen may call it on appear.
    func start() {
        guard !started else { return }
        started = true
        #if canImport(Network)
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor [weak self] in
                self?.isOnline = online
            }
        }
        monitor.start(queue: queue)
        #endif
    }

    /// Stops monitoring and resets to the optimistic default. The app does
    /// not call this today; it exists so a future scene phase can.
    func stop() {
        guard started else { return }
        started = false
        #if canImport(Network)
        monitor.cancel()
        #endif
        isOnline = true
    }
}
