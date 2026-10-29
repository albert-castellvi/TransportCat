import Foundation

/// A computed train position on a line.
struct TrainPosition: Identifiable, Equatable {
    let lineCode: String
    /// Destination as reported by iBus, which also encodes the direction.
    let destination: String
    /// Direction along the station order: true when the train travels toward
    /// the line's last station, false toward the first.
    let forward: Bool
    /// Station the train is approaching.
    let nextStationCode: Int
    /// Seconds until the arrival iBus reported.
    let secondsToArrival: Int
    /// Fraction of the current segment already traveled, clamped to [0, 1].
    let segmentProgress: Double
    /// Computed geographic position of the train.
    let position: GeoPoint

    var id: String { "\(lineCode)-\(destination)-\(nextStationCode)-\(secondsToArrival)" }
}

/// Computes train positions on one line from iBus arrivals.
///
/// Model (spec S6): an arrival at station `i` with `secondsToArrival` means a
/// train is currently on the segment between stations `i-1` and `i`. Its
/// progress along that segment is `1 - secondsToArrival / segmentDuration`,
/// where the segment duration is estimated from the segment's length over a
/// constant line speed (TMB provides no timetable feed). Direction is derived
/// by matching the arrival's destination with the first or last station name.
/// The result is fully deterministic, which is what its tests assert.
struct TrainPositionEngine {
    /// Average commercial speed of Barcelona metro trains, m/s (~33 km/h).
    static let defaultSpeedMetersPerSecond: Double = 9.2

    /// Per-station cumulative distance along the geometry polyline.
    /// Stations are projected perpendicularly onto the nearest polyline
    /// segment and measured along the route, so a sparse polyline (few
    /// vertices) still separates two nearby stations by the real track
    /// distance between them. Vertices between two consecutive stations
    /// contribute intermediate length.
    private let stationDistances: [Double]
    private let cumulativePolyline: [Double]
    private let points: [GeoPoint]
    private let stations: [Station]
    private let speedMetersPerSecond: Double

    /// - Parameters:
    ///   - stations: stations of ONE line, already ordered by ORDRE_ESTACIO.
    ///   - geometry: physical route of the same line.
    ///   - speedMetersPerSecond: override the default speed in tests.
    init?(stations: [Station], geometry: LineGeometry, speedMetersPerSecond: Double = TrainPositionEngine.defaultSpeedMetersPerSecond) {
        guard stations.count >= 2, !geometry.points.isEmpty, speedMetersPerSecond > 0 else { return nil }
        self.points = geometry.points
        self.stations = stations
        self.speedMetersPerSecond = speedMetersPerSecond
        let cumulative = GeoMath.cumulativeDistances(of: geometry.points)
        self.cumulativePolyline = cumulative

        var distances: [Double] = []
        for station in stations {
            let coordinate = GeoPoint(latitude: station.latitude, longitude: station.longitude)
            guard let projection = GeoMath.nearestProjection(of: coordinate, in: geometry.points, cumulative: cumulative) else {
                return nil
            }
            // A polyline that doubles back can place a station behind the
            // previous one; keep the order non-decreasing so no segment
            // length can go negative.
            let previous = distances.last ?? projection.distance
            distances.append(max(projection.distance, previous))
        }
        // Invariant: the clamp above already keeps this non-decreasing. If it
        // is ever violated, `make` degrades to an even distribution instead of
        // drawing a train backwards.
        for index in 1..<distances.count {
            guard distances[index] >= distances[index - 1] else { return nil }
        }
        self.stationDistances = distances
    }

    /// Convenience: computes station distances and falls back to an even
    /// distribution when the projections cannot produce a usable ordering
    /// (degenerate geometry).
    /// - Returns: nil when the inputs cannot produce a usable projection.
    static func make(stations: [Station], geometry: LineGeometry, speedMetersPerSecond: Double = TrainPositionEngine.defaultSpeedMetersPerSecond) -> TrainPositionEngine? {
        if let engine = TrainPositionEngine(stations: stations, geometry: geometry, speedMetersPerSecond: speedMetersPerSecond) {
            return engine
        }
        // Fallback: distribute stations evenly along the polyline when the
        // geometric projection is not usable (degenerate or duplicated
        // station coordinates).
        guard stations.count >= 2, !geometry.points.isEmpty else { return nil }
        let cumulative = GeoMath.cumulativeDistances(of: geometry.points)
        guard let total = cumulative.last, total > 0 else { return nil }
        var projected: [Station] = []
        for (index, station) in stations.enumerated() {
            let fraction = Double(index) / Double(stations.count - 1)
            let distance = fraction * total
            guard let point = GeoMath.point(at: distance, points: geometry.points, cumulative: cumulative) else {
                return nil
            }
            projected.append(Station(
                code: station.code,
                name: station.name,
                orderInLine: station.orderInLine,
                lineCode: station.lineCode,
                latitude: point.latitude,
                longitude: point.longitude,
                id: station.id,
                accessible: station.accessible
            ))
        }
        return TrainPositionEngine(stations: projected, geometry: geometry, speedMetersPerSecond: speedMetersPerSecond)
    }

    /// Computes all positions derivable from the given arrivals. Arrivals may
    /// come from any subset of stops; stops that were never polled simply
    /// contribute nothing. Deterministic.
    func positions(lineCode: String, arrivals: [Arrival]) -> [TrainPosition] {
        var result: [TrainPosition] = []
        for arrival in arrivals {
            guard let seconds = arrival.seconds else { continue }
            guard let nextIndex = stations.firstIndex(where: { $0.code == arrival.stationCode }) else { continue }
            // Direction from destination: match against terminal station names.
            let forward: Bool
            if arrival.destination.caseInsensitiveCompare(stations[stations.count - 1].name) == .orderedSame {
                forward = true
            } else if arrival.destination.caseInsensitiveCompare(stations[0].name) == .orderedSame {
                forward = false
            } else {
                // Unknown destination: assume forward as a benign default.
                forward = true
            }
            // Index of the previous station along the travel direction.
            let previousIndex = forward ? nextIndex - 1 : nextIndex + 1
            guard stations.indices.contains(previousIndex) else { continue }

            let segmentLength = abs(stationDistances[nextIndex] - stationDistances[previousIndex])
            let segmentDuration = segmentLength / speedMetersPerSecond
            let rawProgress = segmentDuration > 0 ? 1.0 - Double(seconds) / segmentDuration : 0
            let progress = min(max(rawProgress, 0), 1)

            let startDistance = forward ? stationDistances[previousIndex] : stationDistances[nextIndex]
            let endDistance = forward ? stationDistances[nextIndex] : stationDistances[previousIndex]
            let distance = startDistance + (endDistance - startDistance) * progress
            guard let position = GeoMath.point(at: distance, points: points, cumulative: cumulativePolyline) else {
                continue
            }
            result.append(TrainPosition(
                lineCode: lineCode,
                destination: arrival.destination,
                forward: forward,
                nextStationCode: arrival.stationCode,
                secondsToArrival: seconds,
                segmentProgress: progress,
                position: position
            ))
        }
        return result
    }
}
