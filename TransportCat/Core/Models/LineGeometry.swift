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
    /// Distance in meters from the first point to each point, taken from
    /// `GeoMath.cumulativeDistances`; index 0 is always 0 (spec S8).
    ///
    /// The table is what turns a station into a position along the route, and
    /// `IncidentSegments.trackPolyline` used to rebuild it — twice, plus two
    /// full projection scans — for every incident run on every 10 Hz tick. It
    /// only depends on `points`, so it is computed once, when the geometry is
    /// decoded, and the render path reuses it.
    let cumulativeDistances: [Double]

    /// Builds the geometry and its distance table together, so no caller can
    /// hold a geometry whose table disagrees with its points (spec S8).
    init(points: [GeoPoint]) {
        self.points = points
        self.cumulativeDistances = GeoMath.cumulativeDistances(of: points)
    }

    /// Identity of a line's route is its polyline; the table is derived from
    /// it and never makes two geometries different.
    static func == (lhs: LineGeometry, rhs: LineGeometry) -> Bool {
        lhs.points == rhs.points
    }
}
