import XCTest
@testable import TransportCat

/// The wording rules of a Rodalies row: the countdown of the app (green "ara",
/// "N min", the wall clock beyond an hour) and the realtime caption of a
/// departure. No clock of its own, no network, no UI.
final class RodaliesDepartureTextTests: XCTestCase {
    private var madrid: TimeZone {
        TimeZone(identifier: "Europe/Madrid")!
    }

    private func at(_ hour: Int, _ minute: Int, _ second: Int = 0) throws -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 11
        components.day = 13
        components.hour = hour
        components.minute = minute
        components.second = second
        components.timeZone = madrid
        return try XCTUnwrap(Calendar(identifier: .gregorian).date(from: components))
    }

    // MARK: - Countdown

    func testImminentDeparturesReadAsNow() throws {
        let now = try at(6, 0)
        XCTAssertEqual(
            RodaliesDepartureText.time(until: now, now: now, timeZone: madrid),
            .now
        )
        XCTAssertEqual(
            RodaliesDepartureText.time(until: now.addingTimeInterval(59), now: now, timeZone: madrid),
            .now
        )
        // The threshold is inclusive, like the metro and bus countdowns.
        XCTAssertEqual(
            RodaliesDepartureText.time(until: now.addingTimeInterval(60), now: now, timeZone: madrid),
            .now
        )
    }

    func testMinutesAreFloored() throws {
        let now = try at(6, 0)
        XCTAssertEqual(
            RodaliesDepartureText.time(until: now.addingTimeInterval(61), now: now, timeZone: madrid),
            .minutes(1)
        )
        XCTAssertEqual(
            RodaliesDepartureText.time(until: now.addingTimeInterval(119), now: now, timeZone: madrid),
            .minutes(1)
        )
        XCTAssertEqual(
            RodaliesDepartureText.time(until: now.addingTimeInterval(59 * 60), now: now, timeZone: madrid),
            .minutes(59)
        )
        XCTAssertEqual(
            RodaliesDepartureText.text(until: now.addingTimeInterval(5 * 60), now: now, timeZone: madrid),
            "5 min"
        )
    }

    /// An hour is still a countdown ("60 min"); beyond it the rider wants the
    /// wall clock of the timetable.
    func testBeyondAnHourTheWallClockReplacesTheCountdown() throws {
        let now = try at(6, 0)
        XCTAssertEqual(
            RodaliesDepartureText.time(until: now.addingTimeInterval(3600), now: now, timeZone: madrid),
            .minutes(60)
        )
        XCTAssertEqual(
            RodaliesDepartureText.time(until: now.addingTimeInterval(3601), now: now, timeZone: madrid),
            .clock("7:00")
        )
    }

    /// The clock is read in the timetable's timezone, never the device's.
    func testTheClockUsesTheTimetableTimezone() throws {
        let now = try at(23, 30)
        let departure = try at(23, 30).addingTimeInterval(75 * 60)
        XCTAssertEqual(
            RodaliesDepartureText.text(until: departure, now: now, timeZone: madrid),
            "0:45"
        )
        // The same instant in UTC reads another hour, which is exactly what the
        // timezone argument is for.
        XCTAssertEqual(
            RodaliesDepartureText.text(
                until: departure,
                now: now,
                timeZone: TimeZone(identifier: "UTC")!
            ),
            "23:45"
        )
    }

    func testOnlyNowIsImminent() {
        XCTAssertTrue(RodaliesTimeText.now.isImminent)
        XCTAssertFalse(RodaliesTimeText.minutes(3).isImminent)
        XCTAssertFalse(RodaliesTimeText.clock("14:35").isImminent)
        XCTAssertEqual(RodaliesTimeText.now.text, "ara")
        XCTAssertEqual(RodaliesTimeText.clock("14:35").text, "14:35")
    }

    // MARK: - Realtime caption

    func testWithoutRealtimeTheRowIsTheTimetable() {
        XCTAssertEqual(RodaliesDepartureText.delay(seconds: nil), .scheduled)
        XCTAssertEqual(RodaliesDepartureText.delay(seconds: nil).text, "Horari previst")
        XCTAssertFalse(RodaliesDepartureText.delay(seconds: nil).isDelayed)
    }

    /// A delay of seconds is the timetable's own resolution, and an early train
    /// is not a delay either.
    func testUnderAMinuteOrEarlyReadsOnTime() {
        XCTAssertEqual(RodaliesDepartureText.delay(seconds: 0), .onTime)
        XCTAssertEqual(RodaliesDepartureText.delay(seconds: 59), .onTime)
        XCTAssertEqual(RodaliesDepartureText.delay(seconds: -120), .onTime)
        XCTAssertEqual(RodaliesDepartureText.delay(seconds: 30).text, "Puntual")
        XCTAssertFalse(RodaliesDepartureText.delay(seconds: 30).isDelayed)
    }

    func testDelaysAreFlooredToMinutes() {
        XCTAssertEqual(RodaliesDepartureText.delay(seconds: 60), .delayed(minutes: 1))
        XCTAssertEqual(RodaliesDepartureText.delay(seconds: 119), .delayed(minutes: 1))
        XCTAssertEqual(RodaliesDepartureText.delay(seconds: 600), .delayed(minutes: 10))
        XCTAssertEqual(RodaliesDepartureText.delay(seconds: 600).text, "Amb retard 10 min")
        XCTAssertTrue(RodaliesDepartureText.delay(seconds: 600).isDelayed)
    }
}
