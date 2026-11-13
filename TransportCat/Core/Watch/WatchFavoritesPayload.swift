import Foundation

/// The favorite places the phone pushes to the watch (spec S22, review W16).
///
/// The list is a whole replacement, not a delta: the watch swaps what it holds
/// for this, so a place unstared on the phone disappears from the wrist and the
/// order the rider set in Explora (drag-to-reorder) is the order they see.
///
/// `syncedAt` is what lets the watch tell "the phone has never sent anything"
/// from "the phone has no favorites", which are two different instructions to a
/// rider.
///
/// Foundation-only and shared by both targets, so the phone and the watch cannot
/// drift apart on the wire shape and the unit tests can read it.
struct WatchFavoritesPayload: Codable, Equatable {
    /// Shape version. A change must bump `contextKey` and `storedKey`.
    static let version = 2

    /// Application-context key. The phone writes the same string
    /// (`WatchSync.contextKey`).
    static let contextKey = "favorites.v2"

    /// `UserDefaults` key of the last payload the watch kept.
    static let storedKey = "watchFavorites.v2"

    let places: [Place]

    /// When the phone encoded this list.
    let syncedAt: Date

    init(places: [Place], syncedAt: Date = Date()) {
        self.places = places
        self.syncedAt = syncedAt
    }

    func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }

    static func decoded(from data: Data) -> WatchFavoritesPayload? {
        try? JSONDecoder().decode(WatchFavoritesPayload.self, from: data)
    }

    /// The payload carried by one application context, or nil when it carries
    /// none (another key, a v1 list, or a corrupt value).
    static func from(context: [String: Any]) -> WatchFavoritesPayload? {
        guard let data = context[contextKey] as? Data else { return nil }
        return decoded(from: data)
    }

    /// The context to push. WatchConnectivity carries property-list values
    /// only, so the JSON travels as `Data`; an empty dictionary means the
    /// payload could not be encoded, and the caller must not send it
    /// (`updateApplicationContext` rejects an empty context).
    var applicationContext: [String: Any] {
        guard let data = encoded() else { return [:] }
        return [Self.contextKey: data]
    }
}
