import Foundation

/// Departure boards of Rodalies stations, from the published timetable pack and
/// the realtime delays.
///
/// Pure rules over decoded values: no networking and no clock of its own, so a
/// board is testable at any date and time.
enum RodaliesDepartures {
    /// Wall-clock times are read in the pack's timezone, not the device's: the
    /// timetable is Europe/Madrid whatever the phone is set to.
    static func timeZone(of schedule: RodaliesSchedule) -> TimeZone {
        TimeZone(identifier: schedule.timezone) ?? .current
    }

    /// The service day to read when the pack does not carry today's date.
    ///
    /// Trip ids are date-coded, so a pack downloaded before a feed reissue does
    /// not carry today and its board would stay empty until the download
    /// succeeds. The newest date with today's weekday is the same timetable on
    /// the same day of the week, which is the best available answer.
    static func fallbackServiceDate(for now: Date, schedule: RodaliesSchedule) -> String? {
        let timeZone = timeZone(of: schedule)
        let calendar = calendar(in: timeZone)
        let weekday = calendar.component(.weekday, from: now)
        let today = calendar.startOfDay(for: now)
        for date in schedule.dates.reversed() {
            guard let day = dateValue(date, timeZone: timeZone), day <= today else { continue }
            if calendar.component(.weekday, from: day) == weekday { return date }
        }
        return nil
    }

    /// The next departures of one station at `now`, soonest first.
    ///
    /// Two service days are read: today's, and yesterday's for the trains whose
    /// GTFS time passed midnight (a departure at 24:10 of yesterday's service
    /// leaves at ten past midnight today). A departure whose realtime-adjusted
    /// time is already behind `now` is gone, even when its scheduled time is
    /// still ahead: the rider is standing on the platform, not reading the
    /// timetable.
    static func nextDepartures(
        stationID: String,
        now: Date,
        schedule: RodaliesSchedule,
        delays: [String: Int] = [:],
        limit: Int = 8
    ) -> [RodaliesDeparture] {
        guard limit > 0 else { return [] }
        let timeZone = timeZone(of: schedule)
        let calendar = calendar(in: timeZone)
        let today = calendar.startOfDay(for: now)
        let todayKey = key(for: today, timeZone: timeZone)

        var departures: [RodaliesDeparture] = []
        // Today's service day: from now on, after-midnight times included
        // (they land on tomorrow's wall clock, which `byAdding` handles).
        let todayService = schedule.days[todayKey] != nil
            ? todayKey
            : fallbackServiceDate(for: now, schedule: schedule)
        if let todayService {
            append(
                rows: schedule.rows(stationID: stationID, date: todayService),
                serviceStart: today,
                now: now,
                delays: delays,
                calendar: calendar,
                into: &departures
            )
        }
        // Yesterday's service day: only its after-midnight times can still be
        // ahead, and they land on today's calendar day.
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today) {
            let yesterdayKey = key(for: yesterday, timeZone: timeZone)
            if yesterdayKey != todayService, schedule.days[yesterdayKey] != nil {
                append(
                    rows: schedule.rows(stationID: stationID, date: yesterdayKey),
                    serviceStart: yesterday,
                    now: now,
                    delays: delays,
                    calendar: calendar,
                    into: &departures
                )
            }
        }

        return departures
            .sorted { left, right in
                if left.expectedAt != right.expectedAt { return left.expectedAt < right.expectedAt }
                return left.id < right.id
            }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - Rows

    /// Turns the rows that are still ahead into departures.
    ///
    /// The only filter is on the realtime-adjusted time: filtering the scheduled
    /// time first would drop the train that is five minutes late right now,
    /// which is exactly the one the rider is waiting for. Yesterday's normal
    /// departures fall out of the same rule, because their wall clock is already
    /// behind `now`.
    private static func append(
        rows: [(line: String, direction: Int, seconds: Int, headsign: String, tripID: String)],
        serviceStart: Date,
        now: Date,
        delays: [String: Int],
        calendar: Calendar,
        into departures: inout [RodaliesDeparture]
    ) {
        for row in rows {
            guard let scheduled = calendar.date(
                byAdding: .second,
                value: row.seconds,
                to: serviceStart
            ) else { continue }
            let departure = RodaliesDeparture(
                tripID: row.tripID,
                lineCode: row.line,
                direction: row.direction,
                headsign: row.headsign,
                scheduledAt: scheduled,
                delaySeconds: delays[row.tripID]
            )
            guard departure.expectedAt >= now else { continue }
            departures.append(departure)
        }
    }

    // MARK: - Calendar helpers

    private static func calendar(in timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    /// "yyyyMMdd" of a date, in the pack's timezone.
    static func key(for date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: date)
    }

    /// The date a "yyyyMMdd" key names, at its local midnight.
    static func dateValue(_ key: String, timeZone: TimeZone) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd"
        return formatter.date(from: key)
    }
}
