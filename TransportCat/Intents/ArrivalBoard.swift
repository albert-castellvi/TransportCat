import Foundation

/// One row of the arrivals widget: a line towards a destination, with its
/// next arrival and the one after it.
struct ArrivalBoardRow: Hashable {
    let line: String
    let destination: String
    let next: Date
    let following: Date?
}

/// Pure rules of the arrivals widget. Foundation-only so the Linux harness
/// covers them; the widget extension only draws what this returns.
enum ArrivalBoard {
    /// An arrival reads "ara" from this long before its date and leaves the
    /// board this long after it.
    static let dueGrace: TimeInterval = 30
    /// Spacing of the timeline entries: how often the board can drop a train
    /// that has left without a new fetch.
    static let tick: TimeInterval = 30
    /// How far ahead the timeline is laid out. WidgetKit may delay a reload,
    /// so this is longer than the refresh interval.
    static let horizon: TimeInterval = 30 * 60
    /// How long a row the feed announced without minutes (FGC, and any
    /// arrival the feed gives no countdown for) may stay on the board. It is
    /// "at the station now" only as long as the data is from now; after the
    /// reload window "ara" would be a guess about a train that left.
    static let announcedLife: TimeInterval = 5 * 60
    /// Age from which the board stops trusting its own snapshot: two missed
    /// five-minute reloads plus one interval of slack. Past this the widget
    /// says how old the data is instead of showing rows, so an exhausted
    /// timeline never reads as "no trains".
    static let staleAfter: TimeInterval = 11 * 60

    /// The rows shown at `date` from arrivals fetched at `fetched`, soonest
    /// first, one row per line and destination.
    ///
    /// An arrival with a countdown leaves the board `dueGrace` after its date.
    /// One the feed announced without minutes (the FGC open feed announces
    /// none) is kept for `announcedLife` after the fetch: it was at the
    /// station when we asked, and that is only true while the data is fresh.
    static func rows(
        _ arrivals: [NextArrival],
        fetched: Date,
        at date: Date,
        limit: Int
    ) -> [ArrivalBoardRow] {
        var rows: [ArrivalBoardRow] = []
        for arrival in arrivals {
            if arrival.announcedWithoutCountdown {
                guard date.timeIntervalSince(fetched) < announcedLife else { continue }
            } else {
                guard arrival.date.addingTimeInterval(dueGrace) > date else { continue }
            }
            if let index = rows.firstIndex(where: {
                $0.line == arrival.line && $0.destination == arrival.destination
            }) {
                let row = rows[index]
                if row.following == nil {
                    rows[index] = ArrivalBoardRow(
                        line: row.line,
                        destination: row.destination,
                        next: row.next,
                        following: arrival.date
                    )
                }
            } else {
                rows.append(
                    ArrivalBoardRow(
                        line: arrival.line,
                        destination: arrival.destination,
                        next: arrival.date,
                        following: nil
                    )
                )
            }
        }
        return Array(rows.prefix(limit))
    }

    /// Dates of the timeline entries built from one fetch: `now`, then one
    /// every `tick` until `horizon`.
    static func entryDates(from now: Date) -> [Date] {
        stride(from: 0, to: horizon, by: tick).map { now.addingTimeInterval($0) }
    }

    // MARK: - Reading the data

    /// Whether the snapshot the board draws is too old to be presented as
    /// live. WidgetKit may delay a reload past `staleAfter`, and the timeline
    /// entries keep ticking; past this age the rows are gone anyway and the
    /// widget has to say why.
    static func isStale(fetched: Date, at date: Date) -> Bool {
        date.timeIntervalSince(fetched) > staleAfter
    }

    /// Whether an arrival is due: the grace the countdown reads "ara" for.
    static func isDue(_ date: Date, now: Date) -> Bool {
        date.timeIntervalSince(now) <= dueGrace
    }

    /// "ara", "1 min", "12 min" for an arrival, never a negative countdown and
    /// never seconds: the whole app speaks minutes (`Arrival.countdownText`,
    /// the Parades timeline) and the feed announces no seconds.
    static func minutesText(until date: Date, now: Date) -> String {
        if isDue(date, now: now) { return String(localized: "ara") }
        return String(localized: "\(Int(ceil(date.timeIntervalSince(now) / 60))) min")
    }

    /// One spoken row: the line, where it goes, how long and, when the pixels
    /// show it, the one after.
    static func spokenRow(_ row: ArrivalBoardRow, now: Date) -> String {
        var text = String(localized: "Línia \(row.line) cap a \(row.destination), ")
            + minutesText(until: row.next, now: now)
        if let following = row.following {
            text += String(localized: ". Següent: ") + minutesText(until: following, now: now)
        }
        return text
    }
}
