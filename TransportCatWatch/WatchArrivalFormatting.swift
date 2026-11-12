import Foundation

/// Pure display rules of the watch screens (spec S22): no SwiftUI and no
/// clock of their own, so they can be exercised without a UI.
enum WatchArrivalFormatting {
    /// Spacing of the screens' local tick: how often a countdown is redrawn and
    /// how often a train that has left drops off without a new fetch.
    static let tick: TimeInterval = 20

    /// An arrival stays on the board this long after its date, the same grace
    /// the iOS widget uses (`ArrivalBoard.dueGrace`). The shared file is not
    /// compiled into the watch target, so the rule is repeated here until it is.
    static let dueGrace: TimeInterval = 30

    /// Minutes until `date`, with the phone's wording (`Arrival.countdownText`):
    /// "<1 min", "3 min", and a lowercase "ara" once it is due or overdue.
    static func countdown(until date: Date, now: Date = Date()) -> String {
        let seconds = Int(date.timeIntervalSince(now))
        guard seconds > 0 else { return "ara" }
        return Arrival.countdownText(seconds: seconds)
    }

    /// The same countdown for VoiceOver, where "min" is not a word: "en 3
    /// minuts", "en menys d'un minut", "ara mateix".
    static func spokenCountdown(until date: Date, now: Date = Date()) -> String {
        let seconds = Int(date.timeIntervalSince(now))
        guard seconds > 0 else { return "ara mateix" }
        if seconds < 60 { return "en menys d'un minut" }
        let minutes = seconds / 60
        return minutes == 1 ? "en 1 minut" : "en \(minutes) minuts"
    }

    /// The arrivals still worth showing at `now` from a fetch made at
    /// `fetched`, in the order the fetcher ranked them and at most `limit`.
    ///
    /// An arrival whose date is not after `fetched` carries no countdown (the
    /// FGC open feed stamps every train with the fetch time), so it never
    /// expires. Everything else leaves `dueGrace` after its date instead of
    /// staying on screen as a stale "ara" until the next pass.
    static func visible(
        _ arrivals: [NextArrival],
        fetched: Date,
        at now: Date,
        limit: Int
    ) -> [NextArrival] {
        guard limit > 0 else { return [] }
        return Array(
            arrivals
                .filter { $0.date <= fetched || $0.date.addingTimeInterval(dueGrace) > now }
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
        "\(arrival.line) cap a \(arrival.destination)"
    }
}

// MARK: - Row identity
//
// `NextArrival` comes from the shared S15 file and carries no identity: its
// line, destination and date are not unique, because the FGC open feed has no
// minutes and stamps every train of one fetch with the same `now`. A list of
// arrivals is therefore identified by position in the fetch, which is the
// order the fetcher's `rank` sorts by (see `WatchPlaceDetailView`).
