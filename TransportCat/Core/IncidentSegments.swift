import Foundation

/// One uninterrupted run of consecutive affected stations of a line (spec S9).
/// The stations keep the line order; the map draws each run as a single red
/// dashed overlay instead of one per station.
struct IncidentRun: Equatable, Identifiable {
    let stations: [Station]

    /// The first station's `orderInLine` identifies the run: two runs of one
    /// line can never start at the same position, and the value survives a
    /// re-poll while the incidents of the run stay the same.
    var id: Int { stations.first?.orderInLine ?? 0 }

    var firstStation: Station? { stations.first }
    var lastStation: Station? { stations.last }
}

/// Groups the affected stations of a line — as `IncidentIndex` reports them —
/// into the runs the metro map overlays (spec S9). Foundation-only and pure
/// so the Linux harness can test it.
enum IncidentSegments {
    /// Runs of stations that are affected and consecutive in line order,
    /// returned in line order.
    ///
    /// - Parameters:
    ///   - stations: the stations of one line. The walk follows `orderInLine`,
    ///     whatever the order of the array.
    ///   - incidents: an `IncidentIndex.incidents` output for the same line.
    ///     A station is affected when its entry exists and is not empty; the
    ///     dictionary is keyed by `Station.code`.
    static func runs(stations: [Station], incidents: [Int: [StationIncident]]) -> [IncidentRun] {
        let ordered = stations.sorted { $0.orderInLine < $1.orderInLine }
        var result: [IncidentRun] = []
        var current: [Station] = []
        for station in ordered {
            if (incidents[station.code]?.isEmpty == false) {
                current.append(station)
            } else if !current.isEmpty {
                result.append(IncidentRun(stations: current))
                current = []
            }
        }
        if !current.isEmpty {
            result.append(IncidentRun(stations: current))
        }
        return result
    }

    /// The geometry points of the line's polyline between the run's first and
    /// last station: both ends are projected onto the track, so the red dashed
    /// overlay follows it instead of cutting across blocks (spec S9).
    ///
    /// Returns nil when the geometry cannot carry the run — fewer than two
    /// stations, no usable polyline, or projections that land the wrong way
    /// round on a route that doubles back. The caller then draws
    /// `stationPolyline` instead.
    static func trackPolyline(for run: IncidentRun, geometry: LineGeometry) -> [GeoPoint]? {
        guard let first = run.firstStation, let last = run.lastStation,
              run.stations.count >= 2, geometry.points.count >= 2 else { return nil }
        let points = geometry.points
        let cumulative = GeoMath.cumulativeDistances(of: points)
        guard let start = GeoMath.nearestProjection(
            of: GeoPoint(latitude: first.latitude, longitude: first.longitude),
            in: points, cumulative: cumulative
        ), let finish = GeoMath.nearestProjection(
            of: GeoPoint(latitude: last.latitude, longitude: last.longitude),
            in: points, cumulative: cumulative
        ), finish.distance > start.distance else { return nil }
        guard let beginCut = GeoMath.point(at: start.distance, points: points, cumulative: cumulative),
              let endCut = GeoMath.point(at: finish.distance, points: points, cumulative: cumulative) else {
            return nil
        }

        var result: [GeoPoint] = [beginCut]
        for index in 1..<(points.count - 1) where cumulative[index] > start.distance && cumulative[index] < finish.distance {
            result.append(points[index])
        }
        result.append(endCut)
        return result.count >= 2 ? result : nil
    }

    /// The run's stations joined by straight segments: the fallback when the
    /// line geometry is missing or cannot carry the run (spec S9). Nil for a
    /// single-station run, which has no segment to draw.
    static func stationPolyline(for run: IncidentRun) -> [GeoPoint]? {
        guard run.stations.count >= 2 else { return nil }
        return run.stations.map { GeoPoint(latitude: $0.latitude, longitude: $0.longitude) }
    }
}
