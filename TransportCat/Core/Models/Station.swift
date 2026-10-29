import Foundation

/// A metro station on a specific line, decoded from the TMB transit GeoJSON.
///
/// The TMB properties differ per line family: main lines (L1–L5, L11) carry
/// rich properties (ID_ESTACIO, accessibility, colors), while L9/L10/FM
/// features only carry CODI_ESTACIO, NOM_ESTACIO, ORDRE_ESTACIO and
/// CODI_LINIA. Everything beyond those is optional.
struct Station: Identifiable, Hashable {
    let code: Int
    let name: String
    let orderInLine: Int
    let lineCode: String
    let latitude: Double
    let longitude: Double
    /// TMB numeric station id (missing on L9/L10/FM features).
    let id: Int?
    /// Whether the station is marked accessible (missing on L9/L10/FM).
    let accessible: Bool?
}

extension Station {
    var coordinateDescription: String {
        String(format: "%.5f, %.5f", latitude, longitude)
    }
}
