import XCTest
@testable import TransportCat

/// First/last and remaining-day departures of the timetable view (spec S19).
///
/// Written before `ScheduleTimetable`. The hand-written packs pin the exact
/// arithmetic — a run's departure at a stop is the service day's midnight plus
/// `startSec`, moved by the stop's `dep` offset — and the real fixtures in
/// `Fixtures/schedule/` check the same rules against TMB's published pack.
final class ScheduleTimetableTests: XCTestCase {
    private let timeZone = TimeZone(identifier: "Europe/Madrid")!

    // MARK: - Helpers

    /// Absolute instant of a wall-clock time in the pack's zone.
    private func date(
        _ year: Int, _ month: Int, _ day: Int,
        _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        return calendar.date(from: components)!
    }

    /// A pack of one metro line (code 1) with two directions:
    /// * direction 0 "Fondo": stops 111 → 112 → 113, `dep` 30/150/330 s from
    ///   the arrival at 111. A run starting at `start` leaves 111 at `start`
    ///   (the 30 s dwell is shared by `start` and the offsets) and 112 at
    ///   `start + 120`.
    /// * direction 1 "Hospital de Bellvitge": stops 113 → 112 → 111, `dep`
    ///   10/70/190 s. A run starting at `start` leaves 111 at `start + 180`.
    private func pack(startsDir0: [[Int]], startsDir1: [[Int]], datesJSON: String) throws -> SchedulePack {
        let index = """
        {"v":1,"timezone":"Europe/Madrid","feedStart":"20261030","feedEnd":"20261105",\
        "lines":[{"mode":"metro","code":1,"file":"metro-1.json"}]}
        """
        let lineJSON = """
        {"v":1,"mode":"metro","code":1,"name":"L1","dates":{\(datesJSON)},"directions":[\
        {"id":0,"headsign":"Fondo","patterns":[{"stops":[111,112,113],"arr":[0,120,300],"dep":[30,150,330]}],\
        "dayTypes":[\(Self.dayTypesJSON(startsDir0))]},\
        {"id":1,"headsign":"Hospital de Bellvitge","patterns":[{"stops":[113,112,111],"arr":[0,60,180],"dep":[10,70,190]}],\
        "dayTypes":[\(Self.dayTypesJSON(startsDir1))]}]}
        """
        return try SchedulePack(index: Data(index.utf8)) { file in
            file == "metro-1.json" ? Data(lineJSON.utf8) : nil
        }
    }

    private static func dayTypesJSON(_ perDayType: [[Int]]) -> String {
        perDayType.map { dayType in
            "[" + dayType.map { "[\($0),0]" }.joined(separator: ",") + "]"
        }.joined(separator: ",")
    }

    /// Reads a schedule fixture from the repository, like the other pack tests.
    private func fixture(_ path: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(path + ".json")
        return try Data(contentsOf: url)
    }

    private func realPack() throws -> SchedulePack {
        try SchedulePack(index: try fixture("schedule/index")) { file in
            try? self.fixture("schedule/" + (file as NSString).deletingPathExtension)
        }
    }

    // MARK: - ScheduledRun departure at a stop

    func testDepartureIsStartMovedByThePatternOffset() throws {
        let pack = try pack(
            startsDir0: [[18000]],
            startsDir1: [[18600]],
            datesJSON: "\"20261030\":0"
        )
        let line = try XCTUnwrap(pack.line(mode: .metro, code: 1))
        let midnight = date(2026, 10, 30)

        let forward = try XCTUnwrap(line.runs(on: date(2026, 10, 30, 12), directionID: 0).first)
        XCTAssertEqual(ScheduleTimetable.departure(of: forward, at: 111), midnight.addingTimeInterval(18000))
        XCTAssertEqual(ScheduleTimetable.departure(of: forward, at: 112), midnight.addingTimeInterval(18120))
        XCTAssertEqual(ScheduleTimetable.departure(of: forward, at: 113), midnight.addingTimeInterval(18300))

        let returnRun = try XCTUnwrap(line.runs(on: date(2026, 10, 30, 12), directionID: 1).first)
        XCTAssertEqual(ScheduleTimetable.departure(of: returnRun, at: 111), midnight.addingTimeInterval(18780))

        // A stop the pattern does not serve has no departure.
        XCTAssertNil(ScheduleTimetable.departure(of: forward, at: 999))
    }

    // MARK: - First and last

    func testFirstLastIsPerDirectionAtTheStop() throws {
        let pack = try pack(
            startsDir0: [[21600, 18000]],
            startsDir1: [[18600]],
            datesJSON: "\"20261030\":0"
        )
        let line = try XCTUnwrap(pack.line(mode: .metro, code: 1))
        let services = ScheduleTimetable.firstLast(line: line, stopCode: 111, date: date(2026, 10, 30, 12))

        XCTAssertEqual(services.count, 2)
        XCTAssertEqual(services[0].directionID, 0)
        XCTAssertEqual(services[0].headsign, "Fondo")
        XCTAssertEqual(services[0].first, date(2026, 10, 30, 5, 0))
        XCTAssertEqual(services[0].last, date(2026, 10, 30, 6, 0))
        XCTAssertEqual(services[1].directionID, 1)
        XCTAssertEqual(services[1].headsign, "Hospital de Bellvitge")
        XCTAssertEqual(services[1].first, date(2026, 10, 30, 5, 13))
        XCTAssertEqual(services[1].last, date(2026, 10, 30, 5, 13))
    }

    func testFirstLastAtAnIntermediateStopUsesItsOffset() throws {
        let pack = try pack(
            startsDir0: [[18000, 21600]],
            startsDir1: [[18600]],
            datesJSON: "\"20261030\":0"
        )
        let line = try XCTUnwrap(pack.line(mode: .metro, code: 1))
        let services = ScheduleTimetable.firstLast(line: line, stopCode: 112, date: date(2026, 10, 30, 12))
        let forward = try XCTUnwrap(services.first { $0.directionID == 0 })
        XCTAssertEqual(forward.first, date(2026, 10, 30, 5, 2))
        XCTAssertEqual(forward.last, date(2026, 10, 30, 6, 2))
    }

    func testFirstLastIsEmptyWithoutServiceOrWithoutTheStop() throws {
        let pack = try pack(
            startsDir0: [[18000]],
            startsDir1: [[]],
            datesJSON: "\"20261030\":0,\"20261031\":1"
        )
        let line = try XCTUnwrap(pack.line(mode: .metro, code: 1))

        XCTAssertTrue(ScheduleTimetable.firstLast(line: line, stopCode: 999, date: date(2026, 10, 30, 12)).isEmpty)
        XCTAssertTrue(ScheduleTimetable.firstLast(line: line, stopCode: 111, date: date(2026, 11, 2, 8)).isEmpty)
        // Direction 1 has an empty day type: no service, no entry.
        let services = ScheduleTimetable.firstLast(line: line, stopCode: 113, date: date(2026, 10, 30, 12))
        XCTAssertEqual(services.map(\.directionID), [0])
    }

    func testFirstAndLastMayCrossMidnight() throws {
        // The day's last trip leaves at 02:00 of the next calendar day; it is
        // still part of this service day (startSec > 86 400).
        let pack = try pack(
            startsDir0: [[18000, 93600]],
            startsDir1: [[]],
            datesJSON: "\"20261030\":0"
        )
        let line = try XCTUnwrap(pack.line(mode: .metro, code: 1))
        let services = ScheduleTimetable.firstLast(line: line, stopCode: 111, date: date(2026, 10, 30, 12))
        let forward = try XCTUnwrap(services.first)
        XCTAssertEqual(forward.first, date(2026, 10, 30, 5, 0))
        XCTAssertEqual(forward.last, date(2026, 10, 31, 2, 0))
        XCTAssertEqual(ScheduleTimetable.clockText(forward.last, timeZone: timeZone), "02:00")
    }

    // MARK: - Remaining departures

    func testDeparturesKeepOnlyWhatHasNotLeftYet() throws {
        let pack = try pack(
            startsDir0: [[18000, 21600]],
            startsDir1: [[18600]],
            datesJSON: "\"20261030\":0"
        )
        let line = try XCTUnwrap(pack.line(mode: .metro, code: 1))
        let departures = ScheduleTimetable.departures(line: line, stopCode: 111, from: date(2026, 10, 30, 5, 5))

        XCTAssertEqual(departures.count, 2)
        XCTAssertEqual(departures.map(\.headsign), ["Hospital de Bellvitge", "Fondo"])
        XCTAssertEqual(departures.map(\.time), [date(2026, 10, 30, 5, 13), date(2026, 10, 30, 6, 0)])
        XCTAssertTrue(departures.allSatisfy { $0.time >= date(2026, 10, 30, 5, 5) })
    }

    func testDeparturesAtAnIntermediateStopUseItsOffset() throws {
        let pack = try pack(
            startsDir0: [[18000]],
            startsDir1: [[18600]],
            datesJSON: "\"20261030\":0"
        )
        let line = try XCTUnwrap(pack.line(mode: .metro, code: 1))
        let departures = ScheduleTimetable.departures(line: line, stopCode: 112, from: date(2026, 10, 30, 0, 0))
        // 112 leaves at start + 120 forward and at start + 60 returning.
        XCTAssertEqual(departures.map(\.time), [date(2026, 10, 30, 5, 2), date(2026, 10, 30, 5, 11)])
        XCTAssertEqual(departures.map(\.directionID), [0, 1])
    }

    func testDeparturesSortTiesByDirection() throws {
        // Direction 0 leaves 112 at start + 120; direction 1 leaves it at
        // start + 60. Starts 21600 and 21660 both leave 112 at 21720, so the
        // list holds two entries at one instant: direction 0 first.
        let pack = try pack(
            startsDir0: [[21600]],
            startsDir1: [[21660]],
            datesJSON: "\"20261030\":0"
        )
        let line = try XCTUnwrap(pack.line(mode: .metro, code: 1))
        let departures = ScheduleTimetable.departures(line: line, stopCode: 112, from: date(2026, 10, 30, 5, 50))
        XCTAssertEqual(departures.count, 2)
        XCTAssertEqual(departures[0].time, departures[1].time)
        XCTAssertEqual(departures.map(\.directionID), [0, 1])
        // Past the shared instant nothing is left to catch.
        XCTAssertTrue(ScheduleTimetable.departures(line: line, stopCode: 112, from: date(2026, 10, 30, 6, 3)).isEmpty)
    }

    func testDeparturesIncludeTheRunThatCrossesMidnight() throws {
        let pack = try pack(
            startsDir0: [[18000, 87000]],
            startsDir1: [[]],
            datesJSON: "\"20261030\":0"
        )
        let line = try XCTUnwrap(pack.line(mode: .metro, code: 1))
        let departures = ScheduleTimetable.departures(line: line, stopCode: 111, from: date(2026, 10, 30, 23, 0))
        XCTAssertEqual(departures.map(\.time), [date(2026, 10, 31, 0, 10)])
        // The rest of the service day has ended by 01:00 of the calendar day.
        XCTAssertTrue(ScheduleTimetable.departures(line: line, stopCode: 111, from: date(2026, 10, 31, 1, 0)).isEmpty)
    }

    // MARK: - Text

    func testClockAndFirstLastText() throws {
        XCTAssertEqual(ScheduleTimetable.clockText(date(2026, 10, 30, 5, 3), timeZone: timeZone), "05:03")
        XCTAssertEqual(ScheduleTimetable.clockText(date(2026, 10, 30, 0, 12), timeZone: timeZone), "00:12")
        let service = TimetableDirection(
            directionID: 0,
            headsign: "Fondo",
            first: date(2026, 10, 30, 5, 0),
            last: date(2026, 10, 31, 0, 12)
        )
        XCTAssertEqual(
            ScheduleTimetable.firstLastText(service, timeZone: timeZone),
            "Primer 05:00 · Últim 00:12"
        )
    }

    // MARK: - Real pack

    func testRealL1FirstLastAtHospitalDeBellvitge() throws {
        let line = try XCTUnwrap(try realPack().line(mode: .metro, code: 1))
        let services = ScheduleTimetable.firstLast(line: line, stopCode: 111, date: date(2026, 10, 30, 12))

        // Friday 2026-10-30 (the pack's first service day) in the real data.
        XCTAssertEqual(services.map(\.headsign), ["Fondo", "Hospital de Bellvitge"])
        XCTAssertEqual(services[0].first, date(2026, 10, 30, 5, 0))
        XCTAssertEqual(services[0].last, date(2026, 10, 31, 2, 0))
        XCTAssertEqual(services[1].first, date(2026, 10, 30, 5, 20, 58))
        XCTAssertEqual(services[1].last, date(2026, 10, 31, 2, 43, 54))
        XCTAssertEqual(
            ScheduleTimetable.firstLastText(services[0], timeZone: timeZone),
            "Primer 05:00 · Últim 02:00"
        )
    }

    func testRealL1RemainingDeparturesAreSortedAfterNow() throws {
        let line = try XCTUnwrap(try realPack().line(mode: .metro, code: 1))
        let from = date(2026, 10, 30, 9, 0)
        let departures = ScheduleTimetable.departures(line: line, stopCode: 111, from: from)

        // 225 onward + 246 return trips from 09:00 of the real Friday pack.
        XCTAssertEqual(departures.count, 471)
        XCTAssertTrue(departures.allSatisfy { $0.time >= from })
        XCTAssertEqual(departures, departures.sorted { $0.time < $1.time })
        XCTAssertEqual(Set(departures.map(\.directionID)), [0, 1])
    }

    func testRealH12BusTimetable() throws {
        let line = try XCTUnwrap(try realPack().line(mode: .bus, code: 212))
        let services = ScheduleTimetable.firstLast(line: line, stopCode: 3225, date: date(2026, 10, 30, 12))
        XCTAssertEqual(services.map(\.headsign), ["Besòs Verneda", "Gornal"])
        XCTAssertEqual(services[0].first, date(2026, 10, 30, 6, 0))
        XCTAssertEqual(services[0].last, date(2026, 10, 30, 22, 30))
        XCTAssertEqual(services[1].first, date(2026, 10, 30, 6, 26))
        XCTAssertEqual(services[1].last, date(2026, 10, 30, 23, 20))

        let evening = ScheduleTimetable.departures(line: line, stopCode: 3225, from: date(2026, 10, 30, 22, 0))
        // 3 toward Besòs Verneda (22:00–22:30) + 8 toward Gornal (22:01–23:20).
        XCTAssertEqual(evening.count, 11)
        XCTAssertTrue(evening.allSatisfy { $0.time >= date(2026, 10, 30, 22, 0) })
    }
}
