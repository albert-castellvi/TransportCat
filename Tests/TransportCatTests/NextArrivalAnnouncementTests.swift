import XCTest
@testable import TransportCat

/// What one place answered: the announced-without-countdown flag the board
/// needs to expire FGC rows (F3) and the outcome that keeps a failed feed
/// apart from an empty one (F2).
final class NextArrivalAnnouncementTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func metroArrival(line: String, destination: String, seconds: Int?) -> Arrival {
        Arrival(
            stationCode: 128,
            lineCode: line,
            destination: destination,
            seconds: seconds,
            rawText: seconds.map { Arrival.countdownText(seconds: $0) } ?? "—"
        )
    }

    private func busArrival(name: String, destination: String, seconds: Int) -> BusArrival {
        BusArrival(
            stopCode: 21201,
            lineCode: 212,
            lineName: name,
            directionID: 1,
            trajectCode: "0011",
            destination: destination,
            seconds: seconds,
            busID: nil,
            rampStatus: nil
        )
    }

    private func train(lineCode: String, destinationName: String?, stoppedAt: String?) -> FGCTrain {
        FGCTrain(
            id: "S1-\(destinationName ?? "x")",
            lineCode: lineCode,
            direction: "A",
            originCode: "SCO",
            destinationCode: "BLG",
            destinationName: destinationName,
            position: GeoPoint(latitude: 41.380, longitude: 2.120),
            nextStopCodes: [],
            isOnTime: true,
            stoppedAtStopCode: stoppedAt,
            unitType: nil,
            occupancy: []
        )
    }

    // MARK: - The flag

    func testFGCTrainsAreAnnouncedWithoutACountdown() {
        let picked = NextArrivalsFetcher.fgcSelection(
            [train(lineCode: "S1", destinationName: "Terrassa", stoppedAt: "CT")],
            stationCode: "CT",
            now: now
        )

        XCTAssertEqual(picked.count, 1)
        XCTAssertTrue(picked[0].announcedWithoutCountdown)
        XCTAssertEqual(picked[0].date, now)
    }

    func testAMetroArrivalWithMinutesCarriesACountdown() {
        let picked = NextArrivalsFetcher.metroSelection(
            [metroArrival(line: "L1", destination: "Fondo", seconds: 120)],
            now: now
        )

        XCTAssertFalse(picked[0].announcedWithoutCountdown)
        XCTAssertEqual(picked[0].date, now.addingTimeInterval(120))
    }

    func testAMetroArrivalWithoutMinutesIsFlaggedAndLandsOnNow() {
        let picked = NextArrivalsFetcher.metroSelection(
            [metroArrival(line: "L1", destination: "Fondo", seconds: nil)],
            now: now
        )

        XCTAssertTrue(picked[0].announcedWithoutCountdown)
        XCTAssertEqual(picked[0].date, now)
    }

    func testBusArrivalsAlwaysCarryACountdown() {
        let picked = NextArrivalsFetcher.busSelection(
            [busArrival(name: "H12", destination: "Gornal", seconds: 240)],
            now: now
        )

        XCTAssertFalse(picked[0].announcedWithoutCountdown)
    }

    // MARK: - The outcome

    func testAnEmptyAnswerIsStillAnAnswer() {
        let outcome = NextArrivalsOutcome.answered([])

        XCTAssertEqual(outcome.arrivals, [])
    }

    func testAnUnreachableFeedYieldsNoArrivals() {
        XCTAssertEqual(NextArrivalsOutcome.unreachable.arrivals, [])
    }

    func testAnAnsweredOutcomeKeepsItsArrivals() {
        let arrival = NextArrival(line: "L1", destination: "Fondo", date: now)

        XCTAssertEqual(NextArrivalsOutcome.answered([arrival]).arrivals, [arrival])
    }
}
