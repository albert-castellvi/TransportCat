import Foundation
import Observation

/// The single owner of arrival fetching on the watch (review W3, W11).
///
/// Every favourite row used to run its own 60 s loop, so a list of six places
/// fired six passes a minute and scrolling back up re-fetched every visible row.
/// Now one pass refreshes every board, the screens read what the store holds,
/// and a place fetched less than `reuseWindow` ago is not fetched again — which
/// is also how the detail screen reuses what the list already has.
///
/// The fetching itself is the shared `NextArrivalsFetcher`, asked for its
/// `NextArrivalsOutcome` so a dead feed is not drawn as "no arrivals" (review
/// W3) and so the watch stops carrying its own copy of the selection rules
/// (review W7).
@MainActor
@Observable
final class WatchArrivalsStore {
    static let shared = WatchArrivalsStore()

    /// Seconds between passes. The countdowns themselves advance on screen
    /// with `WatchArrivalFormatting.tick`, which needs no network.
    static let refreshInterval: TimeInterval = 60

    /// A board younger than this is not fetched again, so two screens asking
    /// for the same place in the same minute do one request, not two.
    static let reuseWindow: TimeInterval = 45

    /// Arrivals per board: the five the detail screen lists, so the list row
    /// and the detail never need two different fetches.
    static let boardLimit = 5

    private(set) var boards: [String: WatchArrivalsBoard] = [:]

    /// Bumped when the app comes back to the foreground (review W2). The
    /// screens key their refresh task on it, so returning from the background
    /// refetches instead of showing what was there an hour ago.
    private(set) var generation = 0

    /// Passes in flight, so the button that shows progress counts them instead
    /// of guessing when the first of two overlapping passes ends.
    private var passes = 0

    /// Places a pass is already fetching, so two passes never ask the same
    /// feed for the same place at once.
    private var inFlight: Set<String> = []

    var isRefreshing: Bool { passes > 0 }

    func board(for placeID: String) -> WatchArrivalsBoard? {
        boards[placeID]
    }

    func bump() {
        generation += 1
    }

    /// Fetches every place whose board is older than `maxAge`; `maxAge: 0`
    /// forces the pass, which is what the reload button asks for.
    ///
    /// - Returns: whether the arrivals on screen changed, so the caller can
    ///   pick between two haptics.
    @discardableResult
    func refresh(_ places: [Place], maxAge: TimeInterval = WatchArrivalsStore.reuseWindow) async -> Bool {
        let stale = places.filter { place in
            guard let board = boards[place.id], let fetchedAt = board.fetchedAt else { return true }
            return maxAge <= 0 || Date().timeIntervalSince(fetchedAt) >= maxAge
        }
        guard !stale.isEmpty else { return false }

        passes += 1
        defer { passes -= 1 }

        guard let client = WatchServices.tmbClient() else {
            // A build without credentials can never answer, and "Sense
            // arribades" would be a claim the app cannot make (review W3). The
            // boards say so instead of staying on "Carregant…" forever.
            for place in stale where !inFlight.contains(place.id) {
                record(.unreachable, for: place, at: Date())
            }
            return false
        }

        var changed = false
        for place in stale where !inFlight.contains(place.id) {
            inFlight.insert(place.id)
            let fetchedAt = Date()
            let outcome = await NextArrivalsFetcher.outcome(
                for: place,
                client: client,
                now: fetchedAt,
                limit: Self.boardLimit
            )
            inFlight.remove(place.id)
            changed = record(outcome, for: place, at: fetchedAt) || changed
        }
        return changed
    }

    /// Keeps the last answered arrivals and records whether this attempt got
    /// through (review W3), so the screens can show honest data with its age
    /// instead of either lying or going blank.
    @discardableResult
    private func record(_ outcome: NextArrivalsOutcome, for place: Place, at date: Date) -> Bool {
        let previous = boards[place.id] ?? WatchArrivalsBoard()
        let board = previous.applying(outcome, at: date)
        boards[place.id] = board
        return board.arrivals != previous.arrivals
    }
}
