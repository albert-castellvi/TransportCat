import XCTest
@testable import TransportCat

/// `ArrivalBoard`: the grouping, expiry, freshness and wording rules of the
/// arrivals widget.
final class ArrivalBoardTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func arrival(_ line: String, _ destination: String, in seconds: TimeInterval) -> NextArrival {
        NextArrival(line: line, destination: destination, date: now.addingTimeInterval(seconds))
    }

    /// An arrival the feed announced without minutes, as FGC sends them: it
    /// carries the fetch time as its date and the flag that says so.
    private func announced(_ line: String, _ destination: String) -> NextArrival {
        NextArrival(
            line: line,
            destination: destination,
            date: now,
            announcedWithoutCountdown: true
        )
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

    func testAnAnnouncedArrivalStaysOnTheBoardWhileTheDataIsFresh() {
        let rows = ArrivalBoard.rows(
            [announced("S1", "Terrassa")],
            fetched: now,
            at: now.addingTimeInterval(ArrivalBoard.announcedLife - 1),
            limit: 5
        )

        XCTAssertEqual(rows.map(\.line), ["S1"])
    }

    func testAnAnnouncedArrivalLeavesTheBoardOnceItsSnapshotAges() {
        // "At the station now" is only true while the data is from now: after
        // the reload window the row must go instead of reading "ara" for half
        // an hour (F3).
        let rows = ArrivalBoard.rows(
            [announced("S1", "Terrassa")],
            fetched: now,
            at: now.addingTimeInterval(ArrivalBoard.announcedLife),
            limit: 5
        )

        XCTAssertTrue(rows.isEmpty)
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

    // MARK: - Freshness

    func testABoardIsStaleOnlyAfterTwoMissedReloads() {
        XCTAssertFalse(ArrivalBoard.isStale(fetched: now, at: now))
        XCTAssertFalse(ArrivalBoard.isStale(fetched: now, at: now.addingTimeInterval(5 * 60)))
        XCTAssertFalse(ArrivalBoard.isStale(fetched: now, at: now.addingTimeInterval(ArrivalBoard.staleAfter)))
        XCTAssertTrue(
            ArrivalBoard.isStale(
                fetched: now,
                at: now.addingTimeInterval(ArrivalBoard.staleAfter + 1)
            )
        )
    }

    func testTheStaleThresholdOutlivesTheAnnouncedLifeAndFitsInTheHorizon() {
        // The stale state must start after the announced rows are gone (they
        // would otherwise be blanked while still defensible) and before the
        // timeline runs out, so the last entries are not the stale ones.
        XCTAssertGreaterThan(ArrivalBoard.staleAfter, ArrivalBoard.announcedLife)
        XCTAssertLessThan(ArrivalBoard.staleAfter, ArrivalBoard.horizon)
    }

    // MARK: - Wording

    func testTheCountdownSpeaksMinutesAndNeverSecondsOrNegativeValues() {
        XCTAssertEqual(ArrivalBoard.minutesText(until: now.addingTimeInterval(20), now: now), "ara")
        XCTAssertEqual(ArrivalBoard.minutesText(until: now.addingTimeInterval(-120), now: now), "ara")
        XCTAssertEqual(ArrivalBoard.minutesText(until: now.addingTimeInterval(90), now: now), "2 min")
        XCTAssertEqual(ArrivalBoard.minutesText(until: now.addingTimeInterval(181), now: now), "4 min")
    }

    func testTheSpokenRowSaysTheLineTheDirectionAndTheNextTwo() {
        let row = ArrivalBoardRow(
            line: "L1",
            destination: "Fondo",
            next: now.addingTimeInterval(120),
            following: now.addingTimeInterval(360)
        )

        XCTAssertEqual(
            ArrivalBoard.spokenRow(row, now: now),
            "Línia L1 cap a Fondo, 2 min. Següent: 6 min"
        )
    }

    func testTheSpokenRowWithoutAFollowingArrivalStopsAfterTheFirst() {
        let row = ArrivalBoardRow(line: "S1", destination: "Terrassa", next: now, following: nil)

        XCTAssertEqual(ArrivalBoard.spokenRow(row, now: now), "Línia S1 cap a Terrassa, ara")
    }
}
