import XCTest
@testable import TransportCat

/// `WatchArrivalsBoard` (review W3): what the watch holds after a fetch, and
/// which of the four empty states a screen is in. Before this, a dead feed and a
/// quiet one both read "Sense arribades".
final class WatchArrivalsBoardTests: XCTestCase {
    private let fetched = Date(timeIntervalSince1970: 1_000_000)

    private func arrival(_ line: String, _ destination: String, in seconds: TimeInterval) -> NextArrival {
        NextArrival(
            line: line,
            destination: destination,
            date: fetched.addingTimeInterval(seconds)
        )
    }

    private func announced(_ line: String, _ destination: String) -> NextArrival {
        NextArrival(line: line, destination: destination, date: fetched, announcedWithoutCountdown: true)
    }

    // MARK: - Applying an outcome

    func testAnsweredReplacesArrivalsAndClearsTheFailure() {
        let board = WatchArrivalsBoard()
            .applying(.unreachable, at: fetched)
            .applying(.answered([arrival("L1", "Fondo", in: 120)]), at: fetched)

        XCTAssertEqual(board.arrivals, [arrival("L1", "Fondo", in: 120)])
        XCTAssertEqual(board.fetchedAt, fetched)
        XCTAssertFalse(board.lastAttemptFailed)
    }

    func testUnreachableKeepsTheLastAnsweredArrivals() {
        let answered = WatchArrivalsBoard()
            .applying(.answered([arrival("L1", "Fondo", in: 120)]), at: fetched)
        let failed = answered.applying(.unreachable, at: fetched.addingTimeInterval(60))

        XCTAssertEqual(failed.arrivals, answered.arrivals)
        XCTAssertEqual(failed.fetchedAt, fetched, "the failure must not move the data's date")
        XCTAssertTrue(failed.lastAttemptFailed)
    }

    func testUnreachableOnAFreshBoardLeavesItEmpty() {
        let board = WatchArrivalsBoard().applying(.unreachable, at: fetched)

        XCTAssertTrue(board.arrivals.isEmpty)
        XCTAssertNil(board.fetchedAt)
        XCTAssertTrue(board.lastAttemptFailed)
    }

    func testAnsweredEmptyIsNotAFailure() {
        let board = WatchArrivalsBoard().applying(.answered([]), at: fetched)

        XCTAssertTrue(board.arrivals.isEmpty)
        XCTAssertFalse(board.lastAttemptFailed)
        XCTAssertEqual(board.fetchedAt, fetched)
    }

    // MARK: - Freshness

    func testFreshnessFollowsTheAppsOwnRule() {
        let answered = WatchArrivalsBoard()
            .applying(.answered([arrival("L1", "Fondo", in: 120)]), at: fetched)

        XCTAssertEqual(answered.freshness(now: fetched.addingTimeInterval(5)), .live)
        XCTAssertEqual(answered.freshness(now: fetched.addingTimeInterval(45)), .delayed)
        XCTAssertEqual(answered.freshness(now: fetched.addingTimeInterval(200)), .stale)
        XCTAssertEqual(
            answered.applying(.unreachable, at: fetched).freshness(now: fetched.addingTimeInterval(5)),
            .delayed,
            "a failed attempt downgrades a live board to delayed"
        )
        XCTAssertEqual(WatchArrivalsBoard().freshness(now: fetched), .unavailable)
    }

    // MARK: - Empty states

    func testNoBoardIsLoading() {
        XCTAssertEqual(WatchBoardStatus.of(nil), .loading)
        XCTAssertEqual(WatchBoardStatus.of(nil).text, "Carregant…")
    }

    func testFailedFetchSaysItCouldNotConnect() {
        let board = WatchArrivalsBoard().applying(.unreachable, at: fetched)

        XCTAssertEqual(WatchBoardStatus.of(board), .unreachable)
        XCTAssertEqual(WatchBoardStatus.unreachable.text, "No s'ha pogut connectar")
    }

    func testAnsweredEmptySaysNothingIsComing() {
        let board = WatchArrivalsBoard().applying(.answered([]), at: fetched)

        XCTAssertEqual(WatchBoardStatus.of(board), .noArrivals)
    }

    func testOnlyExpiredRowsReadAsAgeing() {
        let board = WatchArrivalsBoard()
            .applying(.answered([arrival("L1", "Fondo", in: 10)]), at: fetched)
        let later = fetched.addingTimeInterval(120)
        let rows = WatchArrivalFormatting.visible(board.arrivals, fetched: fetched, at: later, limit: 5)

        XCTAssertTrue(rows.isEmpty)
        XCTAssertEqual(WatchBoardStatus.of(board), .aged)
    }

    func testFailedFetchWithExpiredRowsIsNotAnEmptyStation() {
        let board = WatchArrivalsBoard()
            .applying(.answered([announced("S1", "Terrassa")]), at: fetched)
            .applying(.unreachable, at: fetched.addingTimeInterval(400))
        let later = fetched.addingTimeInterval(400)

        XCTAssertTrue(
            WatchArrivalFormatting.visible(board.arrivals, fetched: fetched, at: later, limit: 5).isEmpty
        )
        XCTAssertEqual(
            WatchBoardStatus.of(board),
            .unreachable,
            "nothing to draw and the last try failed: the reason is the connection"
        )
    }

    func testEveryStatusHasItsOwnWording() {
        let texts = [WatchBoardStatus.loading, .unreachable, .noArrivals, .aged].map(\.text)

        XCTAssertEqual(Set(texts).count, texts.count, "two states must not read the same")
        XCTAssertFalse(texts.contains("Sense arribades"), "the bare sentence claimed a fact we did not have")
    }
}
