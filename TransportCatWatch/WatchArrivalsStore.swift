import Foundation
import Observation

/// The arrivals of one place, as last fetched (review W1, W11).
struct WatchArrivalsBoard: Equatable {
    let arrivals: [NextArrival]
    /// When the fetch that produced `arrivals` was made. The screens expire
    /// rows against it (`WatchArrivalFormatting.visible`), so a train that has
    /// left drops off instead of staying on screen.
    let fetchedAt: Date
}

/// The single owner of arrival fetching on the watch (review W11).
///
/// Every favourite row used to run its own 60 s loop, so a list of six places
/// fired six passes a minute and scrolling back up re-fetched every visible
/// row. Now one pass refreshes every board, the screens read what the store
/// holds, and a place fetched less than `reuseWindow` ago is not fetched again
/// — which is also how the detail screen reuses what the list already has.
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
    static let boardLimit = WatchArrivalsProvider.detailLimit

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
        guard let client = WatchServices.tmbClient() else { return false }

        let now = Date()
        let stale = places.filter { place in
            guard let board = boards[place.id] else { return true }
            return maxAge <= 0 || now.timeIntervalSince(board.fetchedAt) >= maxAge
        }
        guard !stale.isEmpty else { return false }

        passes += 1
        defer { passes -= 1 }

        var changed = false
        for place in stale where !inFlight.contains(place.id) {
            inFlight.insert(place.id)
            let fetchedAt = Date()
            let arrivals = await WatchArrivalsProvider.arrivals(
                for: place,
                client: client,
                limit: Self.boardLimit,
                now: fetchedAt
            )
            inFlight.remove(place.id)

            changed = boards[place.id]?.arrivals != arrivals || changed
            boards[place.id] = WatchArrivalsBoard(arrivals: arrivals, fetchedAt: fetchedAt)
        }
        return changed
    }
}
