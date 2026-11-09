import Foundation

/// Pure display rules of the watch screens (spec S22): no SwiftUI and no
/// clock of their own, so the harness can test them.
enum WatchArrivalFormatting {
    /// Minutes until `date`, rounded up; "Ara" once it is due or overdue.
    static func countdown(until date: Date, now: Date = Date()) -> String {
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return "Ara" }
        return "\(Int(ceil(seconds / 60))) min"
    }

    /// The inline summary of a favorite row ("L1 3 min · L3 5 min").
    static func summary(_ arrivals: [NextArrival], now: Date = Date(), limit: Int = 2) -> String {
        arrivals
            .prefix(limit)
            .map { "\($0.line) \(countdown(until: $0.date, now: now))" }
            .joined(separator: " · ")
    }
}

// MARK: - Row identity
//
// `NextArrival` comes from the shared S15 file and carries no identity: its
// line, destination and date are not unique, because the FGC open feed has no
// minutes and stamps every train of one fetch with the same `now`. A list of
// arrivals is therefore identified by position in the fetch, which is the
// order `NextArrivalsFetcher.rank` sorts by (see `WatchPlaceDetailView`).
