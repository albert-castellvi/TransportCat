import Foundation

/// The time a rider reads next to a Rodalies departure: the app's one countdown
/// rule, stated once so the station board, the Parades timeline and the map
/// card can never say it three ways.
///
/// "ara" while the departure is at most a minute away, "N min" until an hour,
/// and the wall clock of the timetable beyond that — a rider planning the next
/// hour wants "14:35", not "87 min". Times are read in the timetable's own
/// timezone, which `RodaliesDepartures.timeZone(of:)` supplies.
enum RodaliesTimeText: Equatable {
    /// Imminent: drawn in green ("ara").
    case now
    /// Minutes ahead, floored so a countdown never overstates.
    case minutes(Int)
    /// Beyond the countdown window: the wall clock ("14:35").
    case clock(String)

    /// The plain text the row draws.
    var text: String {
        switch self {
        case .now: return String(localized: "ara")
        case .minutes(let minutes): return String(localized: "\(minutes) min")
        case .clock(let clock): return clock
        }
    }

    /// Green only for "ara"; a countdown and a clock time keep the neutral ink.
    var isImminent: Bool {
        if case .now = self { return true }
        return false
    }
}

/// The realtime half of a departure: what the feed says about the train behind
/// the timetable row.
enum RodaliesDelayStatus: Equatable {
    /// No realtime data for this train: the row is the timetable and says so.
    case scheduled
    /// The feed knows the train and it is not late beyond the timetable's own
    /// minute resolution.
    case onTime
    /// Late by `minutes` (floored), drawn in amber.
    case delayed(minutes: Int)

    /// The caption under the line badge (station board, map card).
    var text: String {
        switch self {
        case .scheduled: return String(localized: "Horari previst")
        case .onTime: return String(localized: "Puntual")
        case .delayed(let minutes): return String(localized: "Amb retard \(minutes) min")
        }
    }

    /// Whether the caption reads amber (only an actual delay does).
    var isDelayed: Bool {
        if case .delayed = self { return true }
        return false
    }
}

/// Pure wording rules of the Rodalies rows: no clock of its own and no state, so
/// a board is testable at any date, time and timezone.
enum RodaliesDepartureText {
    /// At or below this many seconds away, a departure reads "ara". Same
    /// threshold `ParadesTimeline` uses for metro and bus.
    static let imminentThresholdSeconds: TimeInterval = 60

    /// Above this many seconds away, the countdown gives way to the wall clock.
    static let clockThresholdSeconds: TimeInterval = 60 * 60

    /// The countdown of one departure at `now`.
    static func time(
        until date: Date,
        now: Date,
        timeZone: TimeZone = .current
    ) -> RodaliesTimeText {
        let seconds = date.timeIntervalSince(now)
        if seconds <= imminentThresholdSeconds { return .now }
        if seconds > clockThresholdSeconds {
            return .clock(clock(date, timeZone: timeZone))
        }
        return .minutes(Int(seconds / 60))
    }

    /// The countdown as the row draws it.
    static func text(
        until date: Date,
        now: Date,
        timeZone: TimeZone = .current
    ) -> String {
        time(until: date, now: now, timeZone: timeZone).text
    }

    /// The realtime caption of one departure.
    ///
    /// A delay under a minute is the timetable's own resolution, not news for
    /// the rider, so it stays "Puntual"; an early train reads the same way.
    /// Minutes are floored: a board that says "1 min" is never late by more
    /// than that.
    static func delay(seconds: Int?) -> RodaliesDelayStatus {
        guard let seconds else { return .scheduled }
        guard seconds >= Int(imminentThresholdSeconds) else { return .onTime }
        return .delayed(minutes: seconds / 60)
    }

    /// The wall clock of a date in the timetable's timezone ("14:35").
    static func clock(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "H:mm"
        return formatter.string(from: date)
    }
}
