import Foundation
import Observation

/// The favorite places the phone synced to the watch, persisted locally
/// (spec S22, review W16).
///
/// The watch is read-only: places are starred on the iPhone and the list arrives
/// through `WatchSessionReceiver`. Keeping the last payload in `UserDefaults`
/// means the list is there at launch, before the phone reconnects or even when
/// it is out of range.
///
/// Shared with the iOS app so the replacement rule — a removed place really goes
/// and the order is the phone's — runs in the unit tests
/// (`WatchFavoritesStoreTests`).
@MainActor
@Observable
final class WatchFavoritesStore {
    static let shared = WatchFavoritesStore()

    /// The places of the last payload, in the phone's order.
    private(set) var places: [Place]

    /// When the phone encoded that payload; nil until the first one arrives,
    /// which is how the empty state knows whether the phone ever synced.
    private(set) var syncedAt: Date?

    private let defaults: UserDefaults

    /// - Parameter defaults: injectable suite, so tests do not touch the watch
    ///   app's domain.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        guard let data = defaults.data(forKey: WatchFavoritesPayload.storedKey),
              let payload = WatchFavoritesPayload.decoded(from: data)
        else {
            places = []
            return
        }
        places = payload.places
        syncedAt = payload.syncedAt
    }

    /// Replaces the list with the phone's.
    ///
    /// The whole list is replaced, never merged: a place unstared on the phone
    /// disappears here, and the order the rider set in Explora is kept.
    ///
    /// - Returns: whether anything changed, so callers can skip a write.
    @discardableResult
    func replace(with payload: WatchFavoritesPayload) -> Bool {
        guard payload.places != places || payload.syncedAt != syncedAt else { return false }
        places = payload.places
        syncedAt = payload.syncedAt
        if let data = payload.encoded() {
            defaults.set(data, forKey: WatchFavoritesPayload.storedKey)
        }
        return true
    }
}
