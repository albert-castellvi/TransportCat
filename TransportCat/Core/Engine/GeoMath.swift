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

    /// Result of projecting a point onto a polyline.
    struct Projection: Equatable {
        /// Distance in meters along the polyline to the perpendicular foot,
        /// on the same scale as `cumulativeDistances`.
        let distance: Double
        /// Index of the segment's start vertex: the foot lies on
        /// `points[segmentIndex] → points[segmentIndex + 1]`.
        let segmentIndex: Int
        /// Position of the foot within the segment, clamped to [0, 1].
        let fraction: Double
        /// Perpendicular distance in meters from `point` to the polyline.
        let offsetMeters: Double
    }

    /// Projects `point` perpendicularly onto the nearest polyline segment and
    /// reports where that foot lies in meters along the polyline.
    ///
    /// The perpendicular foot is computed in a local equirectangular plane
    /// centred on `point` (the approximation used by `distanceMeters`), and
    /// the along-route distance is the segment's cumulative start plus
    /// `fraction * segment length`. Points beside the polyline land on the
    /// foot; points past either end clamp to that end. Ties keep the earliest
    /// segment, so the result is deterministic.
    static func nearestProjection(of point: GeoPoint, in points: [GeoPoint]) -> Projection? {
        nearestProjection(of: point, in: points, cumulative: cumulativeDistances(of: points))
    }

    /// Same as `nearestProjection(of:in:)`, reusing a precomputed cumulative
    /// distance table for `points`.
    static func nearestProjection(of point: GeoPoint, in points: [GeoPoint], cumulative: [Double]) -> Projection? {
        guard !points.isEmpty, points.count == cumulative.count else { return nil }
        if points.count == 1 {
            return Projection(
                distance: cumulative[0],
                segmentIndex: 0,
                fraction: 0,
                offsetMeters: distanceMeters(from: point, to: points[0])
            )
        }
        let metersPerDegree = earthRadiusMeters * .pi / 180
        let lonScale = metersPerDegree * cos(point.latitude * .pi / 180)
        func local(_ vertex: GeoPoint) -> (x: Double, y: Double) {
            ((vertex.longitude - point.longitude) * lonScale, (vertex.latitude - point.latitude) * metersPerDegree)
        }

        var best: Projection?
        for index in 0..<(points.count - 1) {
            let start = local(points[index])
            let end = local(points[index + 1])
            let dx = end.x - start.x
            let dy = end.y - start.y
            let lengthSquared = dx * dx + dy * dy
            // Closest point on the infinite line through the segment is at
            // parameter t; clamping t to [0, 1] handles points beyond an end.
            let rawFraction = lengthSquared > 0 ? -(start.x * dx + start.y * dy) / lengthSquared : 0
            let fraction = min(max(rawFraction, 0), 1)
            let footX = start.x + dx * fraction
            let footY = start.y + dy * fraction
            let offset = sqrt(footX * footX + footY * footY)
            if let current = best, current.offsetMeters <= offset { continue }
            let startDistance = cumulative[index]
            let segmentLength = cumulative[index + 1] - startDistance
            best = Projection(
                distance: startDistance + fraction * segmentLength,
                segmentIndex: index,
                fraction: fraction,
                offsetMeters: offset
            )
        }
        return best
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
