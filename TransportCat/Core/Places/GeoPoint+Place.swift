import Foundation

/// `GeoPoint` lives with the train engine and has no persistence or hashing
/// needs there. `Place` is persisted by `DiskCache` and `FavoritesStore`, so
/// the conformances are added here instead of editing its file (spec S1, T1
/// rule).
///
/// The synthesized `Codable` conformance is only available in the type's own
/// file, so the coding keys and both methods are written by hand.
extension GeoPoint: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(latitude)
        hasher.combine(longitude)
    }
}

extension GeoPoint: Codable {
    private enum CodingKeys: String, CodingKey {
        case latitude
        case longitude
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            latitude: try container.decode(Double.self, forKey: .latitude),
            longitude: try container.decode(Double.self, forKey: .longitude)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(latitude, forKey: .latitude)
        try container.encode(longitude, forKey: .longitude)
    }
}
