import Foundation

/// The arrivals of one place as the watch holds them: what the feeds last
/// answered with, and whether the newest attempt got through at all (review
/// W3, W11).
///
/// A failed attempt keeps the arrivals of the last good one, so the wrist can
/// show something true and say how old it is instead of claiming there is
/// nothing coming. Foundation-only and shared with the iOS app, so the rules
/// run in the unit tests (`WatchArrivalsBoardTests`).
struct WatchArrivalsBoard: Equatable {
    /// Arrivals of the last answered fetch; empty until one answers.
    private(set) var arrivals: [NextArrival] = []
    /// When `arrivals` was fetched; nil until a fetch answers.
    private(set) var fetchedAt: Date?
    /// Whether the newest attempt could not reach the feeds.
    private(set) var lastAttemptFailed = false

    init() {}

    /// The board after an attempt made at `date`.
    func applying(_ outcome: NextArrivalsOutcome, at date: Date) -> WatchArrivalsBoard {
        var board = self
        switch outcome {
        case .answered(let arrivals):
            board.arrivals = arrivals
            board.fetchedAt = date
            board.lastAttemptFailed = false
        case .unreachable:
            // Keep what the last answered fetch gave: an empty list here would
            // be our silence, not the feed's.
            board.lastAttemptFailed = true
        }
        return board
    }

    /// How trustworthy the board is right now, by the app's own rule
    /// (`Freshness.level`).
    func freshness(now: Date) -> DataFreshness {
        Freshness.level(lastUpdate: fetchedAt, now: now, lastAttemptFailed: lastAttemptFailed)
    }
}

/// What a screen says when it has no arrival rows to draw (review W3).
///
/// The four states used to be one sentence, "Sense arribades", which claimed
/// the feeds had answered when they had not.
enum WatchBoardStatus: Equatable {
    /// Nothing has been fetched yet at this launch.
    case loading
    /// The feeds could not be reached.
    case unreachable
    /// The feeds answered and nothing is coming.
    case noArrivals
    /// The feeds answered, but what they announced has since expired.
    case aged

    /// State of a screen with no rows. Call it only after
    /// `WatchArrivalFormatting.visible` came back empty for this board.
    ///
    /// A failed attempt wins over the rest: when nothing can be drawn and the
    /// last try did not get through, the reason is the connection, not the
    /// timetable.
    static func of(_ board: WatchArrivalsBoard?) -> WatchBoardStatus {
        guard let board else { return .loading }
        if board.lastAttemptFailed { return .unreachable }
        return board.arrivals.isEmpty ? .noArrivals : .aged
    }

    /// The line the screen prints, and the one VoiceOver reads.
    var text: String {
        switch self {
        case .loading: return String(localized: "Carregant…")
        case .unreachable: return String(localized: "No s'ha pogut connectar")
        case .noArrivals: return String(localized: "Sense arribades ara mateix")
        case .aged: return String(localized: "Actualitzant…")
        }
    }
}
