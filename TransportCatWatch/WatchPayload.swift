import Foundation

/// The WatchConnectivity application context the phone pushes (spec S22).
///
/// Kept Foundation-only so the encoding/decoding rules run in the harness and
/// so the session delegate stays a thin transport layer.
enum WatchPayload {
    /// Application-context key holding the JSON of `[Place]`; the phone side
    /// writes the same key (`WatchSync.favoritesKey`).
    static let favoritesKey = "favorites"

    /// The JSON of one favorites list.
    static func encode(_ places: [Place]) throws -> Data {
        try JSONEncoder().encode(places)
    }

    /// The places carried by one application context, or nil when it holds no
    /// favorites payload (another key, or a corrupt value).
    static func places(from context: [String: Any]) -> [Place]? {
        guard let data = context[favoritesKey] as? Data else { return nil }
        return try? JSONDecoder().decode([Place].self, from: data)
    }
}
