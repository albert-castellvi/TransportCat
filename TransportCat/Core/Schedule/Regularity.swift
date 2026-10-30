import Foundation

/// What the timetable says about the spacing of the next trains or buses, next
/// to what the feed actually shows (spec S3).
struct RegularityReport: Equatable {
    enum Status: Equatable {
        /// The observed spacing follows the timetable.
        case regular
        /// A hole in the service: an observed gap far longer than scheduled.
        case gap
        /// Trains or buses running on top of each other.
        case bunched
        /// Not enough data to judge: fewer than two live arrivals, or no
        /// scheduled headway to compare against.
        case unknown
    }

    let status: Status
    /// Median gap of the scheduled arrivals in `[now - 10 min, now + 30 min]`.
    let scheduledHeadway: TimeInterval?
    /// Median gap of the live arrivals, in the same order they arrive.
    let observedHeadway: TimeInterval?
    /// Largest gap between two consecutive live arrivals.
    let longestGap: TimeInterval?
}

/// Compares the live spacing of a stop with its timetable (spec S3).
///
/// Pure: no clock and no I/O, so the caller decides what "now" is and the
/// tests can pin exact numbers. High-frequency metro is judged this way
/// because per-train punctuality is not identifiable at a 3-4 min headway.
enum Regularity {
    typealias Status = RegularityReport.Status

    /// Window of scheduled arrivals the headway is measured in: wide enough to
    /// hold several trips at any metro or bus frequency, tight enough to ignore
    /// the peak/off-peak change.
    static let scheduledWindowBefore: TimeInterval = 10 * 60
    static let scheduledWindowAfter: TimeInterval = 30 * 60

    /// A gap of 1.8x the headway, and never under 4 minutes, is a hole.
    static let gapFactor: Double = 1.8
    static let gapMinimum: TimeInterval = 240
    /// A gap of 0.35x the headway is two vehicles on top of each other. Only
    /// meaningful when the headway is long enough for a gap to exist at all.
    static let bunchFactor: Double = 0.35
    static let bunchMinimumHeadway: TimeInterval = 150

    static func assess(live: [Date], scheduled: [Date], now: Date) -> RegularityReport {
        let scheduledHeadway = medianHeadway(
            of: scheduled.filter {
                $0 >= now.addingTimeInterval(-scheduledWindowBefore)
                    && $0 <= now.addingTimeInterval(scheduledWindowAfter)
            }
        )
        let gaps = Self.gaps(of: live)
        let observedHeadway = gaps.isEmpty ? nil : median(gaps)
        let longestGap = gaps.max()

        guard gaps.count >= 1, let scheduledHeadway else {
            return RegularityReport(
                status: .unknown,
                scheduledHeadway: scheduledHeadway,
                observedHeadway: observedHeadway,
                longestGap: longestGap
            )
        }

        let status: Status
        if let longestGap, longestGap >= scheduledHeadway * gapFactor, longestGap >= gapMinimum {
            status = .gap
        } else if scheduledHeadway >= bunchMinimumHeadway,
                  gaps.contains(where: { $0 <= scheduledHeadway * bunchFactor }) {
            status = .bunched
        } else {
            status = .regular
        }
        return RegularityReport(
            status: status,
            scheduledHeadway: scheduledHeadway,
            observedHeadway: observedHeadway,
            longestGap: longestGap
        )
    }

    /// Median of the gaps between consecutive instants of `dates`, ignoring
    /// order: the input does not have to be sorted.
    static func medianHeadway(of dates: [Date]) -> TimeInterval? {
        let gaps = Self.gaps(of: dates)
        return gaps.isEmpty ? nil : median(gaps)
    }

    /// Gaps between consecutive instants, ascending, of a sorted copy of
    /// `dates`. A duplicate instant is a zero gap and is kept: it is a real
    /// bunching signal.
    private static func gaps(of dates: [Date]) -> [TimeInterval] {
        let sorted = dates.sorted()
        guard sorted.count >= 2 else { return [] }
        return zip(sorted.dropFirst(), sorted).map { $0.timeIntervalSince($1) }
    }

    private static func median(_ values: [TimeInterval]) -> TimeInterval {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1
            ? sorted[middle]
            : (sorted[middle - 1] + sorted[middle]) / 2
    }
}
