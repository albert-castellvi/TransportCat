import XCTest
@testable import TransportCat

/// Tests for the pure timetable side of the ETA interpolation: which stop pair
/// a live train's leg spans and when the pack says the train should be on it.
///
/// The pack fixtures are minimal but use the real flat row layout
/// (`[line, direction, seconds, headsign, trip]`) and the real 25661 R1 stops
/// (79403 Sant Adrià de Besòs → 79404 Badalona).
final class RodaliesTripTimingTests: XCTestCase {
    private let timeZone = TimeZone(identifier: "Europe/Madrid")!
    private let tripID = "5116V25661R1"

    private func schedule(
        dates: [String],
        days: [String: [String: [Int]]]
    ) -> RodaliesSchedule {
        RodaliesSchedule(
            timezone: "Europe/Madrid",
            lineCodes: ["R1"],
            headsigns: ["Badalona"],
            tripIDs: [tripID],
            dates: dates,
            days: days
        )
    }

    /// One departure row: line 0, direction 0, `seconds`, headsign 0, trip 0.
    private func row(seconds: Int) -> [Int] {
        [0, 0, seconds, 0, 0]
    }

    private func date(_ key: String, seconds: Int = 0) -> Date {
        let start = RodaliesDepartures.dateValue(key, timeZone: timeZone)!
        return start.addingTimeInterval(TimeInterval(seconds))
    }

    // MARK: - Scheduled leg

    func testScheduledLegReadsDepartureAndDurationFromThePack() throws {
        let pack = schedule(
            dates: ["20261118"],
            days: ["20261118": [
                "79403": row(seconds: 30_600), // 08:30
                "79404": row(seconds: 31_200), // 08:40
            ]]
        )
        let now = date("20261118", seconds: 17 * 3_600)

        let leg = try XCTUnwrap(
            RodaliesTripTiming.scheduledLeg(
                tripID: tripID,
                fromStopID: "79403",
                toStopID: "79404",
                schedule: pack,
                now: now
            )
        )

        XCTAssertEqual(leg.departure, date("20261118", seconds: 30_600))
        XCTAssertEqual(try XCTUnwrap(leg.duration), 600, accuracy: 1e-9)
    }

    /// The pack builder never writes the last stop of a trip (a board never
    /// offers it), so the duration is unknown there and only the departure is.
    func testTheLastStopHasNoDepartureRowSoDurationIsNil() throws {
        let pack = schedule(
            dates: ["20261118"],
            days: ["20261118": ["79403": row(seconds: 30_600)]]
        )

        let leg = try XCTUnwrap(
            RodaliesTripTiming.scheduledLeg(
                tripID: tripID,
                fromStopID: "79403",
                toStopID: "79404",
                schedule: pack,
                now: date("20261118", seconds: 17 * 3_600)
            )
        )

        XCTAssertEqual(leg.departure, date("20261118", seconds: 30_600))
        XCTAssertNil(leg.duration)
    }

    func testUnknownTripOrStopHasNoScheduledLeg() {
        let pack = schedule(
            dates: ["20261118"],
            days: ["20261118": ["79403": row(seconds: 30_600)]]
        )
        let now = date("20261118", seconds: 17 * 3_600)

        XCTAssertNil(
            RodaliesTripTiming.scheduledLeg(
                tripID: "5116V99999R1",
                fromStopID: "79403",
                toStopID: "79404",
                schedule: pack,
                now: now
            )
        )
        XCTAssertNil(
            RodaliesTripTiming.scheduledLeg(
                tripID: tripID,
                fromStopID: "00000",
                toStopID: "79404",
                schedule: pack,
                now: now
            )
        )
    }

    /// A trip leaving at 24:10 belongs to yesterday's service day; its absolute
    /// departure is ten past midnight today.
    func testAfterMidnightTripUsesYesterdaysServiceDay() throws {
        let pack = schedule(
            dates: ["20261117", "20261118"],
            days: ["20261117": [
                "79403": row(seconds: 87_000), // 24:10
                "79404": row(seconds: 87_600), // 24:20
            ]]
        )
        let now = date("20261118", seconds: 20 * 60)

        let leg = try XCTUnwrap(
            RodaliesTripTiming.scheduledLeg(
                tripID: tripID,
                fromStopID: "79403",
                toStopID: "79404",
                schedule: pack,
                now: now
            )
        )

        XCTAssertEqual(leg.departure, date("20261118", seconds: 10 * 60))
        XCTAssertEqual(try XCTUnwrap(leg.duration), 600, accuracy: 1e-9)
    }

    /// A stale pack that only carries yesterday does not animate yesterday's
    /// daytime timetable as if it were today's: the estimate falls back.
    func testAStaleDateWithoutTodaysTripDoesNotAnimateYesterday() {
        let pack = schedule(
            dates: ["20261117"],
            days: ["20261117": ["79403": row(seconds: 30_600)]]
        )

        XCTAssertNil(
            RodaliesTripTiming.scheduledLeg(
                tripID: tripID,
                fromStopID: "79403",
                toStopID: "79404",
                schedule: pack,
                now: date("20261118", seconds: 17 * 3_600)
            )
        )
    }

    // MARK: - Stop pair

    func testLegStopsFollowsTheFeedStatusSemantics() {
        XCTAssertEqual(
            RodaliesTripTiming.legStops(
                status: "INCOMING_AT",
                currentStopID: nil,
                nextStopID: "79404",
                previousStopID: "79403"
            )?.from,
            "79403"
        )
        XCTAssertEqual(
            RodaliesTripTiming.legStops(
                status: "INCOMING_AT",
                currentStopID: nil,
                nextStopID: "79404",
                previousStopID: "79403"
            )?.to,
            "79404"
        )
        XCTAssertEqual(
            RodaliesTripTiming.legStops(
                status: "IN_TRANSIT_TO",
                currentStopID: "79403",
                nextStopID: "79404",
                previousStopID: nil
            )?.from,
            "79403"
        )
        XCTAssertEqual(
            RodaliesTripTiming.legStops(
                status: "STOPPED_AT",
                currentStopID: "79403",
                nextStopID: "79404",
                previousStopID: nil
            )?.from,
            "79403"
        )
    }

    func testLegStopsRejectsUnknownStopPairs() {
        // No previous stop for an arriving train: no leg.
        XCTAssertNil(
            RodaliesTripTiming.legStops(
                status: "INCOMING_AT",
                currentStopID: nil,
                nextStopID: "79404",
                previousStopID: nil
            )
        )
        // The same stop on both ends is not a leg.
        XCTAssertNil(
            RodaliesTripTiming.legStops(
                status: "STOPPED_AT",
                currentStopID: "79404",
                nextStopID: "79404",
                previousStopID: nil
            )
        )
        // An unknown status has no defined origin.
        XCTAssertNil(
            RodaliesTripTiming.legStops(
                status: nil,
                currentStopID: "79403",
                nextStopID: "79404",
                previousStopID: nil
            )
        )
        // No next stop: nothing to interpolate towards.
        XCTAssertNil(
            RodaliesTripTiming.legStops(
                status: "STOPPED_AT",
                currentStopID: "79403",
                nextStopID: nil,
                previousStopID: nil
            )
        )
    }
}