import Foundation
import Observation

/// The favorite places the phone synced to the watch, persisted locally
/// (spec S22).
///
/// The watch is read-only: places are starred on the iPhone and the list
/// arrives through `WatchSessionReceiver`. Keeping the last payload in
/// `UserDefaults` means the list is there at launch, before the phone
/// reconnects or even when it is out of range.
@MainActor
@Observable
final class WatchFavoritesStore {
    static let shared = WatchFavoritesStore()

    /// Versioned key. A model change must use a new key.
    static let placesKey = "watchFavoritePlaces.v1"

    private(set) var places: [Place]

    private let defaults: UserDefaults

    /// - Parameter defaults: injectable suite, so tests do not touch the
    ///   watch app's domain.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        guard let data = defaults.data(forKey: Self.placesKey),
              let stored = try? JSONDecoder().decode([Place].self, from: data)
        else {
            places = []
            return
        }
        places = stored
    }

    /// Replaces the list with the synced one.
    ///
    /// - Returns: whether the list changed, so callers can skip a write.
    @discardableResult
    func replace(with synced: [Place]) -> Bool {
        guard synced != places else { return false }
        places = synced
        if let data = try? JSONEncoder().encode(synced) {
            defaults.set(data, forKey: Self.placesKey)
        }
        return true
    }
}
