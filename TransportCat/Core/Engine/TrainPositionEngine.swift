import Foundation

/// A computed train position on a line: one instance per physical train.
struct TrainPosition: Identifiable, Equatable {
    /// Stable identity of the train run (S1): line, service code and route
    /// code. Never contains the countdown, so the same train keeps its `id`
    /// across polls and the UI can animate it instead of replacing it.
    let id: String
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
    /// Fraction of the current segment already traveled, clamped to
    /// [0.05, 1] by the progress formula (S3).
    let segmentProgress: Double
    /// Distance in meters along the route polyline of this position. This is
    /// the value `TrainMotion` interpolates between polls.
    let routeDistance: Double
    /// Route distance of the station the train is approaching: the marker is
    /// never drawn past it, because the train waits at the platform.
    let segmentEndDistance: Double
    /// True while the train is stopped at the station (`secondsToArrival`
    /// of 15 s or less, the threshold calibrated against the live feed, S3).
    let isDwelling: Bool
    /// Computed geographic position of the train.
    let position: GeoPoint

    /// A copy of this position re-placed along the route, keeping every
    /// poll-derived field (countdown, dwelling state, direction). Used by
    /// `TrainMotion` to publish an interpolated marker.
    func moved(toRouteDistance distance: Double, position point: GeoPoint) -> TrainPosition {
        TrainPosition(
            id: id,
            lineCode: lineCode,
            destination: destination,
            forward: forward,
            nextStationCode: nextStationCode,
            secondsToArrival: secondsToArrival,
            segmentProgress: segmentProgress,
            routeDistance: distance,
            segmentEndDistance: segmentEndDistance,
            isDwelling: isDwelling,
            position: point
        )
    }
}

/// Computes train positions on one line from iBus arrivals.
///
/// Model: an arrival at station `i` with `secondsToArrival` means a train is
/// currently on the segment between station `i-1` and `i` when it travels
/// forward, or between `i+1` and `i` when it travels backward. Its progress
/// along that segment is `1 - clamp((seconds - 45) / max(20, segmentDuration -
/// 45), 0, 0.95)`, where the segment duration is the segment length over a
/// constant line speed (TMB provides no timetable feed). The 45 s offset and
/// the 0.95 cap keep the marker off the platform until the arrival is real,
/// and the 20 s floor keeps very short segments usable.
///
/// Direction comes from `codi_via` (1 = toward the last station, 2 = toward
/// the first) and falls back to matching the destination name with the two
/// terminals. Arrivals of the same train (`codi_servei` + `codi_trajecte`) at
/// several stations collapse into one position, the one with the smallest
/// countdown. The result is fully deterministic, which is what its tests
/// assert.
struct TrainPositionEngine {
    /// Average commercial speed of Barcelona metro trains, m/s (~29 km/h).
    /// Calibrated against the live feed: 9.2 m/s left 88% of the trains
    /// clamped at the start of their segment (S3).
    static let defaultSpeedMetersPerSecond: Double = 8.0

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

    /// Speed the engine was built with, in m/s. `TrainMotion` extrapolates
    /// with it between polls.
    var speed: Double { speedMetersPerSecond }

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

    /// Geographic point `distance` meters along the route polyline, clamped to
    /// its ends. The interpolation `TrainMotion` uses between polls.
    func point(atRouteDistance distance: Double) -> GeoPoint? {
        GeoMath.point(at: distance, points: points, cumulative: cumulativePolyline)
    }

    /// Computes all positions derivable from the given arrivals, one per
    /// physical train. Arrivals may come from any subset of stops; stops that
    /// were never polled simply contribute nothing. Sorted by `id`, because a
    /// dictionary's order is not deterministic and the output must be.
    func positions(lineCode: String, arrivals: [Arrival]) -> [TrainPosition] {
        // S1: collapse the arrivals of the same train onto the one with the
        // smallest countdown, which is the next station it will reach.
        var nextArrivalByID: [String: Arrival] = [:]
        for arrival in arrivals {
            guard let seconds = arrival.seconds else { continue }
            let id = identifier(for: arrival, seconds: seconds, lineCode: lineCode)
            if let current = nextArrivalByID[id], let currentSeconds = current.seconds, currentSeconds <= seconds {
                continue
            }
            nextArrivalByID[id] = arrival
        }

        var result: [TrainPosition] = []
        for (id, arrival) in nextArrivalByID {
            guard let seconds = arrival.seconds else { continue }
            guard let nextIndex = stations.firstIndex(where: { $0.code == arrival.stationCode }) else { continue }
            let forward = isForward(arrival)
            // Index of the previous station along the travel direction.
            let previousIndex = forward ? nextIndex - 1 : nextIndex + 1
            guard stations.indices.contains(previousIndex) else { continue }

            let segmentLength = abs(stationDistances[nextIndex] - stationDistances[previousIndex])
            let segmentDuration = segmentLength / speedMetersPerSecond
            // S3: the train keeps covering the last 45 s and the final 5% of
            // the segment without the marker landing on the platform.
            let remainingRatio = min(max((Double(seconds) - 45) / max(20, segmentDuration - 45), 0), 0.95)
            let progress = 1 - remainingRatio

            // S8: both directions interpolate from the station already left
            // to the station being approached, so an arriving backward train
            // is drawn beside the station it is about to reach.
            let distance = stationDistances[previousIndex]
                + (stationDistances[nextIndex] - stationDistances[previousIndex]) * progress
            guard let geoPoint = point(atRouteDistance: distance) else { continue }

            result.append(TrainPosition(
                id: id,
                lineCode: lineCode,
                destination: arrival.destination,
                forward: forward,
                nextStationCode: arrival.stationCode,
                secondsToArrival: seconds,
                segmentProgress: progress,
                routeDistance: distance,
                segmentEndDistance: stationDistances[nextIndex],
                isDwelling: seconds <= 15,
                position: geoPoint
            ))
        }
        return result.sorted { $0.id < $1.id }
    }

    /// S1: identity of the train run. `codi_servei` plus `codi_trajecte`
    /// identify one physical train, so the countdown is deliberately absent.
    /// Arrivals without a service code cannot be collapsed: their identity
    /// includes the station and the countdown.
    private func identifier(for arrival: Arrival, seconds: Int, lineCode: String) -> String {
        guard let serviceCode = arrival.serviceCode else {
            return "\(lineCode)-\(arrival.destination)-\(arrival.stationCode)-\(seconds)"
        }
        return "\(lineCode)-\(serviceCode)-\(arrival.trajectCode ?? "")"
    }

    /// S2: direction along the station order. `codi_via` wins; matching the
    /// destination against the two terminal names is only the fallback for
    /// feeds without a via, and an unknown destination defaults to forward.
    private func isForward(_ arrival: Arrival) -> Bool {
        if let via = arrival.via {
            return via == 1
        }
        if arrival.destination.caseInsensitiveCompare(stations[stations.count - 1].name) == .orderedSame {
            return true
        }
        if arrival.destination.caseInsensitiveCompare(stations[0].name) == .orderedSame {
            return false
        }
        return true
    }
}
