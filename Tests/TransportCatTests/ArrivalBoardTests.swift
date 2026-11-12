import XCTest
@testable import TransportCat

/// `ArrivalBoard`: the grouping and expiry rules of the arrivals widget.
final class ArrivalBoardTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func arrival(_ line: String, _ destination: String, in seconds: TimeInterval) -> NextArrival {
        NextArrival(line: line, destination: destination, date: now.addingTimeInterval(seconds))
    }

    func testRowsGroupByLineAndDestinationKeepingTheFollowingArrival() {
        let rows = ArrivalBoard.rows(
            [
                arrival("L1", "Fondo", in: 120),
                arrival("L3", "Zona Universitària", in: 180),
                arrival("L1", "Fondo", in: 360),
                arrival("L1", "Hospital de Bellvitge", in: 400),
                arrival("L1", "Fondo", in: 600),
            ],
            fetched: now,
            at: now,
            limit: 5
        )

        XCTAssertEqual(rows.map(\.line), ["L1", "L3", "L1"])
        XCTAssertEqual(rows[0].next, now.addingTimeInterval(120))
        XCTAssertEqual(rows[0].following, now.addingTimeInterval(360))
        XCTAssertNil(rows[1].following)
    }

    func testAnArrivalLeavesTheBoardAfterItsGraceAndTheNextOneTakesItsRow() {
        let arrivals = [arrival("L1", "Fondo", in: 120), arrival("L1", "Fondo", in: 360)]

        let during = ArrivalBoard.rows(arrivals, fetched: now, at: now.addingTimeInterval(140), limit: 5)
        XCTAssertEqual(during.first?.next, now.addingTimeInterval(120))

        let after = ArrivalBoard.rows(arrivals, fetched: now, at: now.addingTimeInterval(150), limit: 5)
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(after.first?.next, now.addingTimeInterval(360))
        XCTAssertNil(after.first?.following)
    }

    func testAnArrivalWithoutCountdownNeverExpiresBetweenFetches() {
        let rows = ArrivalBoard.rows(
            [arrival("S1", "Terrassa", in: 0)],
            fetched: now,
            at: now.addingTimeInterval(20 * 60),
            limit: 5
        )

        XCTAssertEqual(rows.map(\.line), ["S1"])
    }

    func testRowsRespectTheLimit() {
        let rows = ArrivalBoard.rows(
            [arrival("H12", "A", in: 60), arrival("V15", "B", in: 90), arrival("D50", "C", in: 120)],
            fetched: now,
            at: now,
            limit: 2
        )

        XCTAssertEqual(rows.map(\.line), ["H12", "V15"])
    }

    func testEntryDatesStartNowAndCoverTheHorizon() {
        let dates = ArrivalBoard.entryDates(from: now)

        XCTAssertEqual(dates.first, now)
        XCTAssertEqual(dates.count, Int(ArrivalBoard.horizon / ArrivalBoard.tick))
        XCTAssertEqual(dates.last, now.addingTimeInterval(ArrivalBoard.horizon - ArrivalBoard.tick))
    }
}
