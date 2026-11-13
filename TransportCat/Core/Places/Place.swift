import Foundation

/// What kind of transport place a `Place` is (spec S1).
///
/// The raw value is part of `Place.id` ("metroStation:128"), so it is persisted
/// by `FavoritesStore` and `DiskCache`: renaming a case would orphan the stored
/// favorites.
enum PlaceKind: String, Codable, Hashable, CaseIterable {
    case metroStation
    case busStop
    case fgcStation
    /// Renfe Rodalies de Catalunya (spec S1 of the Rodalies mode). Added after
    /// the first three, so every raw value already persisted keeps decoding.
    case rodaliesStation
}

/// A searchable, favoritable transport place: a metro station, a bus stop, an
/// FGC station or a Rodalies station (spec S1).
///
/// `lineCodes` holds the code each operator's screens understand: the metro
/// display name ("L1"), the FGC route code ("S1"), the TMB bus commercial
/// name ("H12") or the Rodalies line code ("R2N"). `code` is the operator
/// identifier: the TMB `ID_ESTACIO`, the bus `CODI_PARADA`, the FGC `inicials`
/// or the Rodalies `stop_id`.
struct Place: Codable, Hashable, Identifiable {
    let kind: PlaceKind
    let code: String
    let name: String
    let position: GeoPoint
    let lineCodes: [String]
    let accessible: Bool?

    /// Stable identity across launches: "<kind>:<code>".
    var id: String { "\(kind.rawValue):\(code)" }
}
