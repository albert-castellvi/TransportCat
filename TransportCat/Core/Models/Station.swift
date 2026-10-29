import Foundation

/// A metro station on a specific line, decoded from the TMB transit GeoJSON.
///
/// All 11 lines return the same property set (25 keys, including `ID_ESTACIO`
/// and `NOM_TIPUS_ACCESSIBILITAT`), so nothing here is dropped per line family.
/// The two derived fields stay optional because the schema does not guarantee
/// them, and an absent property must never fail the decode.
struct Station: Identifiable, Hashable {
    let code: Int
    let name: String
    let orderInLine: Int
    let lineCode: String
    let latitude: Double
    let longitude: Double
    /// TMB numeric `ID_ESTACIO` (present on every line today, optional in the
    /// schema).
    let id: Int?
    /// `NOM_TIPUS_ACCESSIBILITAT == "Accessible"` (present on every line today,
    /// optional in the schema).
    let accessible: Bool?
}

extension Station {
    var coordinateDescription: String {
        String(format: "%.5f, %.5f", latitude, longitude)
    }
}
