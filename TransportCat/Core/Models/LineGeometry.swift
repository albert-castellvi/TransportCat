import Foundation

/// A geographic point in WGS84. Kept independent from CoreLocation so the
/// engine and its tests stay deterministic and platform-light.
struct GeoPoint: Equatable {
    let latitude: Double
    let longitude: Double
}

/// Ordered polyline of a line's physical route, decoded from the TMB
/// `/transit/linies/metro/{code}` GeoJSON (a FeatureCollection whose geometry
/// is the line MultiLineString). Points follow the TMB coordinate order
/// [lng, lat] and are converted on decode.
struct LineGeometry: Equatable {
    let points: [GeoPoint]

    static func == (lhs: LineGeometry, rhs: LineGeometry) -> Bool {
        lhs.points == rhs.points
    }
}
