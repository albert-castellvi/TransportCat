import Foundation

/// The timetable side of one estimated leg: the scheduled departure at the
/// stop the train left and, when the pack knows the next stop too, the leg's
/// scheduled duration.
struct RodaliesScheduledLeg: Equatable {
    /// Scheduled departure at the origin stop, in the device's absolute time.
    let departure: Date
    /// Scheduled running time to the next stop; nil when the pack has no
    /// departure row there (the last stop of a trip has none) or the values do
    /// not advance.
    let duration: TimeInterval?
}

/// Pure rules that turn a live train and the timetable pack into the leg the
/// map interpolates.
///
/// No clock and no networking: `now` is a parameter, so a leg is testable at a
/// fixed service date. `RodaliesTripProgress` then turns the leg into a
/// distance; this type only decides *which* stops the leg spans and *when* the
/// timetable says the train should be on it.
enum RodaliesTripTiming {
    /// The stop pair an estimate spans, from the feed's status semantics.
    ///
    /// - `INCOMING_AT`: the vehicle is arriving at `nextStopID`, so the leg
    ///   runs from the previous stop in the direction to it.
    /// - `STOPPED_AT` / `IN_TRANSIT_TO`: the vehicle is at, or has just left,
    ///   `currentStopID`; the leg runs from there to `nextStopID`.
    /// - Anything else, an unknown previous stop or a pair that does not
    ///   advance returns nil and the map keeps the feed's point.
    static func legStops(
        status: String?,
        currentStopID: String?,
        nextStopID: String?,
        previousStopID: String?
    ) -> (from: String, to: String)? {
        guard let to = nextStopID, !to.isEmpty else { return nil }
        let from: String?
        switch status {
        case "INCOMING_AT":
            from = previousStopID
        case "STOPPED_AT", "IN_TRANSIT_TO":
            from = currentStopID
        default:
            from = nil
        }
        guard let from, !from.isEmpty, from != to else { return nil }
        return (from, to)
    }

    /// The scheduled departure at `fromStopID` and the leg duration to
    /// `toStopID` for `tripID` at the service day of `now`.
    ///
    /// Only today's pack date and yesterday's after-midnight trips are read: a
    /// trip id belongs to one service day and those are the only two whose
    /// departure can still be ahead of a live train. Returning nil for a stale
    /// pack is deliberate: the estimate falls back to the feed's point rather
    /// than animating yesterday's timetable.
    static func scheduledLeg(
        tripID: String,
        fromStopID: String,
        toStopID: String,
        schedule: RodaliesSchedule,
        now: Date
    ) -> RodaliesScheduledLeg? {
        let timeZone = RodaliesDepartures.timeZone(of: schedule)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let today = calendar.startOfDay(for: now)
        let todayKey = RodaliesDepartures.key(for: today, timeZone: timeZone)

        if let fromSeconds = departureSeconds(
            tripID: tripID,
            stationID: fromStopID,
            date: todayKey,
            schedule: schedule
        ) {
            return leg(
                tripID: tripID,
                toStopID: toStopID,
                fromSeconds: fromSeconds,
                serviceStart: today,
                dateKey: todayKey,
                timeZone: timeZone,
                schedule: schedule
            )
        }

        // A trip that leaves after midnight belongs to yesterday's service day
        // and its GTFS seconds pass 86400.
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today) else { return nil }
        let yesterdayKey = RodaliesDepartures.key(for: yesterday, timeZone: timeZone)
        guard let fromSeconds = departureSeconds(
            tripID: tripID,
            stationID: fromStopID,
            date: yesterdayKey,
            schedule: schedule
        ), fromSeconds >= 24 * 60 * 60 else { return nil }
        return leg(
            tripID: tripID,
            toStopID: toStopID,
            fromSeconds: fromSeconds,
            serviceStart: yesterday,
            dateKey: yesterdayKey,
            timeZone: timeZone,
            schedule: schedule
        )
    }

    // MARK: - Helpers

    private static func leg(
        tripID: String,
        toStopID: String,
        fromSeconds: Int,
        serviceStart: Date,
        dateKey: String,
        timeZone: TimeZone,
        schedule: RodaliesSchedule
    ) -> RodaliesScheduledLeg? {
        guard let departure = date(
            serviceStart: serviceStart,
            seconds: fromSeconds,
            timeZone: timeZone
        ) else { return nil }
        let toSeconds = departureSeconds(
            tripID: tripID,
            stationID: toStopID,
            date: dateKey,
            schedule: schedule
        )
        let duration = toSeconds.map { TimeInterval($0 - fromSeconds) }.flatMap { $0 > 0 ? $0 : nil }
        return RodaliesScheduledLeg(departure: departure, duration: duration)
    }

    /// The departure seconds of one trip at one stop on one service date. The
    /// pack row already carries the departure; a trip that calls the station
    /// twice keeps the first row, which is the earliest.
    private static func departureSeconds(
        tripID: String,
        stationID: String,
        date: String,
        schedule: RodaliesSchedule
    ) -> Int? {
        schedule.rows(stationID: stationID, date: date)
            .first { $0.tripID == tripID }?
            .seconds
    }

    /// Absolute date of `seconds` after the service day's midnight. Seconds can
    /// pass 86400 for after-midnight trips.
    private static func date(serviceStart: Date, seconds: Int, timeZone: TimeZone) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(byAdding: .second, value: seconds, to: serviceStart)
    }
}