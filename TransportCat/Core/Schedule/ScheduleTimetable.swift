import Foundation

/// One direction's service at one stop on one day (spec S19): the earliest
/// and the latest scheduled departure from that stop.
struct TimetableDirection: Hashable, Identifiable {
    let directionID: Int
    let headsign: String
    let first: Date
    let last: Date

    var id: Int { directionID }
}

/// One scheduled departure from one stop (spec S19).
struct TimetableDeparture: Hashable, Identifiable {
    let directionID: Int
    let headsign: String
    let time: Date

    var id: String { "\(directionID)-\(time.timeIntervalSince1970)" }
}

/// Timetable readings of a schedule pack line for the sheets: first and last
/// departure per direction at a stop, and the theoretical departures that
/// remain in the service day (spec S19).
///
/// Pure over `ScheduleLine` values: the service-day resolution, the day types
/// and the absolute instants come from the pack itself, so the sheets only
/// format what this returns. A departure at a stop is the run's first-stop
/// departure (`start`) moved by the stop's `dep` offset inside its pattern —
/// the same arithmetic `ScheduledRun.arrival(at:)` does for arrivals.
enum ScheduleTimetable {
    /// Theoretical departure from `stopCode` of one run, or nil when the
    /// pattern skips the stop.
    static func departure(of run: ScheduledRun, at stopCode: Int) -> Date? {
        guard let index = run.pattern.stops.firstIndex(of: stopCode),
              run.pattern.departures.indices.contains(index) else { return nil }
        return run.originArrival.addingTimeInterval(Double(run.pattern.departures[index]))
    }

    /// First and last departure at `stopCode` per direction, on the service
    /// day of `date`. Directions the stop does not appear in are absent, and
    /// a date without service yields no entries.
    static func firstLast(line: ScheduleLine, stopCode: Int, date: Date) -> [TimetableDirection] {
        var result: [TimetableDirection] = []
        for direction in line.directions {
            let times = departuresOfDay(line: line, directionID: direction.id, date: date, stopCode: stopCode)
            guard let first = times.min(), let last = times.max() else { continue }
            result.append(TimetableDirection(
                directionID: direction.id,
                headsign: direction.headsign,
                first: first,
                last: last
            ))
        }
        return result
    }

    /// Departures from `stopCode` of every direction from `from` until the end
    /// of its service day (spec S19: "the rest of the service day"). Sorted
    /// by time; equal instants keep direction order so the list is stable.
    static func departures(line: ScheduleLine, stopCode: Int, from: Date) -> [TimetableDeparture] {
        var seen = Set<String>()
        return line.runs(on: from)
            .compactMap { run -> TimetableDeparture? in
                guard let time = departure(of: run, at: stopCode), time >= from else { return nil }
                return TimetableDeparture(directionID: run.directionID, headsign: run.headsign, time: time)
            }
            .sorted { lhs, rhs in
                if lhs.time != rhs.time { return lhs.time < rhs.time }
                return lhs.directionID < rhs.directionID
            }
            // Two runs of one direction at the same second are one row for the
            // rider, and the row id (direction + instant) must be unique.
            .filter { seen.insert($0.id).inserted }
    }

    /// "05:03" — a 24-hour clock in the pack's own time zone, so a run that
    /// crosses midnight reads "02:00", not "26:00".
    static func clockText(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("HH:mm")
        return formatter.string(from: date)
    }

    /// The Catalan first/last line of one direction (spec S19 wording):
    /// "Primer 05:00 · Últim 00:12".
    static func firstLastText(_ service: TimetableDirection, timeZone: TimeZone) -> String {
        String(localized: "Primer \(clockText(service.first, timeZone: timeZone)) · Últim \(clockText(service.last, timeZone: timeZone))")
    }

    /// Departure instants at `stopCode` of one direction on the service day of
    /// `date`, in pack order.
    private static func departuresOfDay(
        line: ScheduleLine,
        directionID: Int,
        date: Date,
        stopCode: Int
    ) -> [Date] {
        line.runs(on: date, directionID: directionID).compactMap { run in
            departure(of: run, at: stopCode)
        }
    }
}
