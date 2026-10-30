import Foundation

/// Estimated offset of one bus against its timetable (spec S4). Shown in the
/// UI only as "estimat": it is a match, not a measurement.
struct DelayEstimate: Equatable {
    enum Confidence: Equatable {
        /// Three or more stops agreeing within 45 s, on a frequent line.
        case high
        case medium
        case low
    }

    /// Seconds late (positive) or early (negative), rounded.
    let seconds: Int
    let confidence: Confidence
    /// Timetable arrival of the matched run at the first observed stop.
    let scheduledArrival: Date
}

/// Matches the observations of one bus against the timetable of its line
/// (spec S4).
///
/// The feed reports an ETA per stop, never a trip identity, so a bus is placed
/// by trying every run of the direction that serves its observed stops and
/// keeping the one whose arrival offsets agree best: the smaller the spread
/// between the offsets of the same bus at several stops, the better the match.
///
/// Pure: no clock and no I/O, the caller passes `now` and the observations it
/// accumulated for one poll.
enum BusDelay {
    /// A run whose per-stop offsets disagree by more than this is not the bus.
    static let maxSpread: TimeInterval = 90
    /// Below half the scheduled headway the match is not ambiguous: the next
    /// run would have been at least that far off.
    static let ambiguityFactor: Double = 0.5
    /// Confidence thresholds.
    static let highMinimumStops = 3
    static let highSpread: TimeInterval = 45
    static let highHeadwayFactor: Double = 4
    static let mediumHeadwayFactor: Double = 2.5

    static func estimate(
        observations: [(stopCode: Int, eta: Date)],
        line: ScheduleLine,
        directionID: Int,
        now: Date
    ) -> DelayEstimate? {
        guard !observations.isEmpty else { return nil }

        let runs = line.runs(on: now, directionID: directionID)
        var best: (mean: TimeInterval, spread: TimeInterval, run: ScheduledRun, stops: Int, scheduledArrival: Date)?

        for run in runs {
            // Only the stops this run actually serves can say anything about it.
            var offsets: [TimeInterval] = []
            var firstStop: (index: Int, scheduled: Date)?
            for observation in observations {
                guard let arrival = run.arrival(at: observation.stopCode),
                      let patternIndex = run.pattern.stops.firstIndex(of: observation.stopCode) else { continue }
                offsets.append(observation.eta.timeIntervalSince(arrival))
                if firstStop == nil || patternIndex < firstStop!.index {
                    firstStop = (index: patternIndex, scheduled: arrival)
                }
            }
            guard let firstStop, !offsets.isEmpty else { continue }
            let mean = offsets.reduce(0, +) / Double(offsets.count)
            let spread = (offsets.max() ?? 0) - (offsets.min() ?? 0)
            guard spread < maxSpread else { continue }
            if best == nil || abs(mean) < abs(best!.mean) {
                best = (mean: mean, spread: spread, run: run, stops: offsets.count, scheduledArrival: firstStop.scheduled)
            }
        }

        guard let best else { return nil }

        // A line so frequent that the matched run is barely better than its
        // neighbour is not identified at all.
        let headway = scheduledHeadway(line: line, directionID: directionID, at: best.run.pattern.stops.first, now: now)
        if let headway, abs(best.mean) > headway * ambiguityFactor { return nil }

        return DelayEstimate(
            seconds: Int(best.mean.rounded()),
            confidence: confidence(stops: best.stops, spread: best.spread, headway: headway, delay: best.mean),
            scheduledArrival: best.scheduledArrival
        )
    }

    private static func confidence(
        stops: Int,
        spread: TimeInterval,
        headway: TimeInterval?,
        delay: TimeInterval
    ) -> DelayEstimate.Confidence {
        guard let headway else { return .low }
        let size = abs(delay)
        if stops >= highMinimumStops,
           spread < highSpread,
           headway >= size * highHeadwayFactor {
            return .high
        }
        if headway >= size * mediumHeadwayFactor {
            return .medium
        }
        return .low
    }

    /// Scheduled headway at one stop, from the arrivals of the same window
    /// `Regularity` measures in; nil when the stop has fewer than two.
    private static func scheduledHeadway(
        line: ScheduleLine,
        directionID: Int,
        at stopCode: Int?,
        now: Date
    ) -> TimeInterval? {
        guard let stopCode else { return nil }
        let arrivals = line.arrivals(at: stopCode, directionID: directionID, on: now).filter {
            $0 >= now.addingTimeInterval(-Regularity.scheduledWindowBefore)
                && $0 <= now.addingTimeInterval(Regularity.scheduledWindowAfter)
        }
        return Regularity.medianHeadway(of: arrivals)
    }
}
