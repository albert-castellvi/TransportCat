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
}

/// A searchable, favoritable transport place: a metro station, a bus stop or an
/// FGC station (spec S1).
///
/// `lineCodes` holds the code each operator's screens understand: the metro
/// display name ("L1"), the FGC route code ("S1") or the TMB bus commercial
/// name ("H12"). `code` is the operator identifier: the TMB `ID_ESTACIO`, the
/// bus `CODI_PARADA` or the FGC `inicials`.
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
