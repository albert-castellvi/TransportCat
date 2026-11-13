import XCTest
@testable import TransportCat

/// `WatchArrivalFormatting` (reviews W7, W8): the wording the wrist prints and
/// the rules that take a row off the screen. Both are the app's own now
/// (`ArrivalBoard.minutesText`, `AnnouncedLife`), so the watch cannot quietly
/// disagree with the widget or with the phone.
final class WatchArrivalFormattingTests: XCTestCase {
    private let fetched = Date(timeIntervalSince1970: 1_000_000)

    private func at(_ seconds: TimeInterval) -> Date {
        fetched.addingTimeInterval(seconds)
    }

    private func counted(_ line: String, _ destination: String, in seconds: TimeInterval) -> NextArrival {
        NextArrival(line: line, destination: destination, date: at(seconds))
    }

    private func announced(_ line: String, _ destination: String) -> NextArrival {
        NextArrival(line: line, destination: destination, date: fetched, announcedWithoutCountdown: true)
    }

    // MARK: - Wording

    func testCountdownUsesTheAppsMinutes() {
        XCTAssertEqual(WatchArrivalFormatting.countdown(until: at(120), now: fetched), "2 min")
        XCTAssertEqual(WatchArrivalFormatting.countdown(until: at(61), now: fetched), "2 min")
        XCTAssertEqual(WatchArrivalFormatting.countdown(until: at(600), now: fetched), "10 min")
    }

    func testImminentReadsAraLowerCase() {
        XCTAssertEqual(WatchArrivalFormatting.countdown(until: at(5), now: fetched), "ara")
        XCTAssertEqual(WatchArrivalFormatting.countdown(until: at(-60), now: fetched), "ara")
        XCTAssertEqual(WatchArrivalFormatting.countdown(until: fetched, now: fetched), "ara")
    }

    func testSpokenCountdownIsASentence() {
        XCTAssertEqual(WatchArrivalFormatting.spokenCountdown(until: at(30), now: fetched), "en menys d'un minut")
        XCTAssertEqual(WatchArrivalFormatting.spokenCountdown(until: at(60), now: fetched), "en 1 minut")
        XCTAssertEqual(WatchArrivalFormatting.spokenCountdown(until: at(180), now: fetched), "en 3 minuts")
        XCTAssertEqual(WatchArrivalFormatting.spokenCountdown(until: at(-5), now: fetched), "ara mateix")
    }

    func testLeadSaysWhereTheTrainGoes() {
        XCTAssertEqual(
            WatchArrivalFormatting.lead(counted("L1", "Fondo", in: 120)),
            "L1 cap a Fondo"
        )
    }

    // MARK: - Expiry (W7)

    func testCountedArrivalLeavesAfterTheGrace() {
        let board = [counted("L1", "Fondo", in: 120)]

        XCTAssertEqual(
            WatchArrivalFormatting.visible(board, fetched: fetched, at: at(130), limit: 5).count,
            1
        )
        XCTAssertTrue(
            WatchArrivalFormatting.visible(board, fetched: fetched, at: at(151), limit: 5).isEmpty,
            "a train that left must go, not sit there reading ara"
        )
    }

    func testAnnouncedArrivalStopsBeingAraWhenTheFetchAges() {
        let board = [announced("S1", "Terrassa")]

        XCTAssertEqual(
            WatchArrivalFormatting.visible(board, fetched: fetched, at: at(60), limit: 5).count,
            1,
            "FGC rows are true for a while: we asked the feed a minute ago"
        )
        XCTAssertEqual(
            WatchArrivalFormatting.visible(board, fetched: fetched, at: at(4 * 60), limit: 5).count,
            1
        )
        XCTAssertTrue(
            WatchArrivalFormatting.visible(board, fetched: fetched, at: at(ArrivalBoard.announcedLife), limit: 5)
                .isEmpty,
            "past announcedLife the feed's 'at the station now' is a guess"
        )
        XCTAssertEqual(
            WatchArrivalFormatting.countdown(until: fetched, now: at(120)),
            "ara",
            "while it is on the board it reads ara"
        )
    }

    func testAnnouncedAndCountedRowsLiveByDifferentRules() {
        let board = [announced("S1", "Terrassa"), counted("L1", "Fondo", in: 120)]
        let stillThere = WatchArrivalFormatting.visible(board, fetched: fetched, at: at(160), limit: 5)

        XCTAssertEqual(stillThere.map(\.line), ["S1"])
    }

    func testVisibleRespectsTheLimitAndOrder() {
        let board = [
            counted("L1", "Fondo", in: 60),
            counted("L3", "Zona Universitària", in: 120),
            counted("L5", "Vall d'Hebron", in: 180)
        ]

        XCTAssertEqual(
            WatchArrivalFormatting.visible(board, fetched: fetched, at: fetched, limit: 5).map(\.line),
            ["L1", "L3", "L5"],
            "the fetcher's order is kept: it already sorted by soonest"
        )
        XCTAssertEqual(
            WatchArrivalFormatting.visible(board, fetched: fetched, at: fetched, limit: 2).map(\.line),
            ["L1", "L3"]
        )
        XCTAssertTrue(WatchArrivalFormatting.visible(board, fetched: fetched, at: fetched, limit: 0).isEmpty)
    }

    func testSoonestIsTheFirstVisibleOne() {
        let board = [
            counted("L1", "Fondo", in: 10),
            counted("L3", "Zona Universitària", in: 180)
        ]

        XCTAssertEqual(
            WatchArrivalFormatting.soonest(board, fetched: fetched, at: at(60))?.line,
            "L3",
            "the first one had already left"
        )
        XCTAssertNil(
            WatchArrivalFormatting.soonest(board, fetched: fetched, at: at(400))
        )
    }
}
