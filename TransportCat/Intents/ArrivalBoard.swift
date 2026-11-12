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

    /// The rows shown at `date` from arrivals fetched at `fetched`, soonest
    /// first, one row per line and destination.
    ///
    /// An arrival whose date is not after `fetched` carries no countdown (the
    /// FGC open feed announces none), so it never expires between fetches.
    static func rows(
        _ arrivals: [NextArrival],
        fetched: Date,
        at date: Date,
        limit: Int
    ) -> [ArrivalBoardRow] {
        var rows: [ArrivalBoardRow] = []
        for arrival in arrivals {
            guard arrival.date <= fetched || arrival.date.addingTimeInterval(dueGrace) > date else {
                continue
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
}
