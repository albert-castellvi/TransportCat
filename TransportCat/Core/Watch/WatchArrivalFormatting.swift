import Foundation

/// Pure display rules of the watch screens (spec S22, reviews W4, W7, W8):
/// no SwiftUI and no clock of their own.
///
/// Shared with the iOS app so the rules run in the unit tests
/// (`WatchArrivalFormattingTests`); the wording and the expiry are the same ones
/// the arrivals widget uses.
enum WatchArrivalFormatting {
    /// Spacing of the screens' local tick: how often a countdown is redrawn and
    /// how often a train that has left drops off without a new fetch.
    static let tick: TimeInterval = 20

    /// Minutes until `date`, with the app's single wording
    /// (`ArrivalBoard.minutesText`): "ara" from `dueGrace` before the date,
    /// then "1 min", "12 min".
    static func countdown(until date: Date, now: Date = Date()) -> String {
        ArrivalBoard.minutesText(until: date, now: now)
    }

    /// The same countdown for VoiceOver, where "min" is not a word: "en 3
    /// minuts", "en menys d'un minut", "ara mateix".
    static func spokenCountdown(until date: Date, now: Date = Date()) -> String {
        let seconds = Int(date.timeIntervalSince(now))
        guard seconds > 0 else { return String(localized: "ara mateix") }
        if seconds < 60 { return String(localized: "en menys d'un minut") }
        let minutes = seconds / 60
        return minutes == 1 ? String(localized: "en 1 minut") : String(localized: "en \(minutes) minuts")
    }

    /// The arrivals still worth showing at `now` from a fetch made at
    /// `fetched`, in the order the fetcher ranked them and at most `limit`.
    ///
    /// Same expiry as the widget's board: an arrival with a countdown leaves
    /// `dueGrace` after its date, and one the feed announced without minutes
    /// (the FGC open feed never sends any, and i-Metro sometimes omits them)
    /// only stays while the fetch is younger than `announcedLife`. That last
    /// rule is what stopped every FGC train from reading "ara" forever (review
    /// W7). `ArrivalBoard.rows` applies the same rules but groups by line and
    /// destination for the widget; the watch lists one arrival per row, so the
    /// rules are applied here instead of calling it.
    static func visible(
        _ arrivals: [NextArrival],
        fetched: Date,
        at now: Date,
        limit: Int
    ) -> [NextArrival] {
        guard limit > 0 else { return [] }
        return Array(
            arrivals
                .filter { arrival in
                    if arrival.announcedWithoutCountdown {
                        return now.timeIntervalSince(fetched) < ArrivalBoard.announcedLife
                    }
                    return arrival.date.addingTimeInterval(ArrivalBoard.dueGrace) > now
                }
                .prefix(limit)
        )
    }

    /// The soonest arrival still worth showing, or nil when the place has none.
    static func soonest(
        _ arrivals: [NextArrival],
        fetched: Date,
        at now: Date
    ) -> NextArrival? {
        visible(arrivals, fetched: fetched, at: now, limit: 1).first
    }

    /// What a row says before its countdown: the line and where it goes
    /// ("L1 cap a Fondo"). The destination is not optional on the watch: at a
    /// station the soonest train is often not the one the rider wants.
    static func lead(_ arrival: NextArrival) -> String {
        String(localized: "\(arrival.line) cap a \(arrival.destination)")
    }
}

// MARK: - Row identity
//
// `NextArrival` comes from the shared S15 file and carries no identity: its
// line, destination and date are not unique, because the FGC open feed has no
// minutes and stamps every train of one fetch with the same `now`. A list of
// arrivals is therefore identified by position in the fetch, which is the
// order the fetcher's `rank` sorts by (see `WatchPlaceDetailView`).
