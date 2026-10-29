import Foundation

/// Deterministic planar-ish geo math for the train position engine.
/// Distances use the equirectangular approximation: for the ~10 km scale of
/// a metro line the error is far below any visually meaningful level.
enum GeoMath {
    static let earthRadiusMeters = 6_371_000.0

    /// Approximate distance between two points, in meters.
    static func distanceMeters(from a: GeoPoint, to b: GeoPoint) -> Double {
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLat = lat2 - lat1
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let x = dLon * cos((lat1 + lat2) / 2)
        return sqrt(x * x + dLat * dLat) * earthRadiusMeters
    }

    /// Cumulative distances along a polyline, starting at 0.
    static func cumulativeDistances(of points: [GeoPoint]) -> [Double] {
        guard !points.isEmpty else { return [] }
        var cumulative: [Double] = [0]
        for index in 1..<points.count {
            cumulative.append(cumulative[index - 1] + distanceMeters(from: points[index - 1], to: points[index]))
        }
        return cumulative
    }

    /// Index of the polyline vertex nearest to `point`.
    static func nearestVertexIndex(of point: GeoPoint, in points: [GeoPoint]) -> Int? {
        guard !points.isEmpty else { return nil }
        var bestIndex = 0
        var bestDistance = Double.greatestFiniteMagnitude
        for (index, vertex) in points.enumerated() {
            let distance = distanceMeters(from: point, to: vertex)
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = index
            }
        }
        return bestIndex
    }

    /// Geographic point at `distance` meters along the polyline described by
    /// `points` and its `cumulative` distances. Clamps to the ends.
    static func point(at distance: Double, points: [GeoPoint], cumulative: [Double]) -> GeoPoint? {
        guard let first = cumulative.first, let last = cumulative.last, points.count == cumulative.count, !points.isEmpty else {
            return nil
        }
        let clamped = min(max(distance, first), last)
        if clamped <= first { return points[0] }
        if clamped >= last { return points[points.count - 1] }
        for index in 1..<cumulative.count where cumulative[index] >= clamped {
            let startDistance = cumulative[index - 1]
            let segmentLength = cumulative[index] - startDistance
            let fraction = segmentLength > 0 ? (clamped - startDistance) / segmentLength : 0
            let a = points[index - 1]
            let b = points[index]
            return GeoPoint(
                latitude: a.latitude + (b.latitude - a.latitude) * fraction,
                longitude: a.longitude + (b.longitude - a.longitude) * fraction
            )
        }
        return points[points.count - 1]
    }
}
