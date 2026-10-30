import Foundation

/// Positions of the trains a line *should* have right now, from its timetable
/// alone (spec S5).
///
/// Lines L9N, L9S, L10N, L10S and the Montjuïc funicular have no live feed, so
/// the map draws their scheduled trains instead of an empty line. The marker is
/// always flagged `isTheoretical` and the UI labels it: it is a timetable, never
/// an observed train.
enum TheoreticalFleet {
    /// One position per scheduled run in progress at `now`.
    ///
    /// `stations` must be the whole line in station order, which is what the
    /// line's topology load returns; `engine` supplies the route distances the
    /// interpolation happens on. Runs whose pattern has a stop missing from
    /// `stations` are skipped whole: a partially placed train would draw a
    /// segment that does not exist.
    static func positions(
        line: ScheduleLine,
        stations: [Station],
        engine: TrainPositionEngine,
        now: Date
    ) -> [TrainPosition] {
        let distances = engine.stationRouteDistances
        guard stations.count >= 2, distances.count == stations.count else { return [] }
        var indexByCode: [Int: Int] = [:]
        for (index, station) in stations.enumerated() {
            indexByCode[station.code] = index
        }

        let lineCode = String(line.code)
        var positions: [TrainPosition] = []
        for direction in line.directions {
            for run in line.runs(on: now, directionID: direction.id) {
                guard let position = place(
                    run,
                    lineCode: lineCode,
                    stations: stations,
                    distances: distances,
                    indexByCode: indexByCode,
                    engine: engine,
                    now: now
                ) else { continue }
                positions.append(position)
            }
        }
        return positions.sorted { $0.id < $1.id }
    }

    /// Places one run on the line, or nil when it is not in progress at `now`
    /// or its pattern does not fit the topology.
    private static func place(
        _ run: ScheduledRun,
        lineCode: String,
        stations: [Station],
        distances: [Double],
        indexByCode: [Int: Int],
        engine: TrainPositionEngine,
        now: Date
    ) -> TrainPosition? {
        let pattern = run.pattern
        guard pattern.stops.count >= 2,
              pattern.arrivals.count == pattern.stops.count,
              pattern.departures.count == pattern.stops.count else { return nil }

        var routeIndexes: [Int] = []
        routeIndexes.reserveCapacity(pattern.stops.count)
        for stop in pattern.stops {
            guard let index = indexByCode[stop] else { return nil }
            routeIndexes.append(index)
        }
        let firstIndex = routeIndexes[0]
        let lastIndex = routeIndexes[routeIndexes.count - 1]
        guard firstIndex != lastIndex else { return nil }
        let forward = firstIndex < lastIndex

        // The run's own clock: `start` is the departure from the first stop and
        // `end` the arrival at the last one, both absolute.
        let origin = run.originArrival
        guard now >= origin, now <= run.end else { return nil }

        let arrivals = pattern.arrivals.map { origin.addingTimeInterval(Double($0)) }
        let departures = pattern.departures.map { origin.addingTimeInterval(Double($0)) }

        // Dwell: the train sits at a platform between its arrival and its
        // departure, which is where most of a metro timetable's minutes are.
        for index in 0..<pattern.stops.count where now >= arrivals[index] && now <= departures[index] {
            let distance = distances[routeIndexes[index]]
            guard let point = engine.point(atRouteDistance: distance) else { return nil }
            return TrainPosition(
                id: identifier(run),
                lineCode: lineCode,
                destination: run.headsign,
                forward: forward,
                nextStationCode: stations[routeIndexes[index]].code,
                secondsToArrival: 0,
                segmentProgress: 1,
                routeDistance: distance,
                segmentEndDistance: distance,
                isDwelling: true,
                position: point,
                heading: engine.heading(atRouteDistance: distance, forward: forward),
                isTheoretical: true
            )
        }

        // Between two stops the position is a linear interpolation in time of
        // the two route distances: the timetable says when, the geometry says
        // where.
        for index in 0..<(pattern.stops.count - 1) where now >= departures[index] && now <= arrivals[index + 1] {
            let from = routeIndexes[index]
            let to = routeIndexes[index + 1]
            let span = arrivals[index + 1].timeIntervalSince(departures[index])
            let progress = span > 0
                ? min(max(now.timeIntervalSince(departures[index]) / span, 0), 1)
                : 1
            let distance = distances[from] + (distances[to] - distances[from]) * progress
            guard let point = engine.point(atRouteDistance: distance) else { return nil }
            return TrainPosition(
                id: identifier(run),
                lineCode: lineCode,
                destination: run.headsign,
                forward: forward,
                nextStationCode: stations[to].code,
                secondsToArrival: max(0, Int(arrivals[index + 1].timeIntervalSince(now).rounded())),
                segmentProgress: progress,
                routeDistance: distance,
                segmentEndDistance: distances[to],
                isDwelling: false,
                position: point,
                heading: engine.heading(atRouteDistance: distance, forward: forward),
                isTheoretical: true
            )
        }
        return nil
    }

    /// Stable identity of a scheduled train: the direction and the departure
    /// from the service day's midnight, which no other run of the day shares.
    private static func identifier(_ run: ScheduledRun) -> String {
        "T\(run.directionID)-\(run.startSec)"
    }
}
