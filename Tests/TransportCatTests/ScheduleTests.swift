import XCTest
@testable import TransportCat

/// Decoding and service-day resolution of the schedule pack (spec S2).
///
/// The tiny packs here are hand-written JSON in the pack's own format, so a
/// failure points at the decoder or at the day lookup instead of at the feed.
final class ScheduleTests: XCTestCase {
    private let timeZone = TimeZone(identifier: "Europe/Madrid")!

    // MARK: - Helpers

    private func pack(lines: String, feedVersion: String = "feed-1") throws -> SchedulePack {
        let index = """
        {"v":1,"generatedAt":"2026-10-30T00:00:00Z","feedVersion":"\(feedVersion)",\
        "feedStart":"20261030","feedEnd":"20261105","timezone":"Europe/Madrid",\
        "lines":[\(lines)]}
        """
        return try SchedulePack(index: Data(index.utf8)) { _ in nil }
    }

    /// A pack of one metro line whose single file is `lineJSON`.
    private func metroPack(lineJSON: String, feedVersion: String = "feed-1") throws -> SchedulePack {
        let index = """
        {"v":1,"generatedAt":"2026-10-30T00:00:00Z","feedVersion":"\(feedVersion)",\
        "feedStart":"20261030","feedEnd":"20261105","timezone":"Europe/Madrid",\
        "lines":[{"mode":"metro","code":94,"name":"L9N","file":"metro-94.json"}]}
        """
        return try SchedulePack(index: Data(index.utf8)) { file in
            file == "metro-94.json" ? Data(lineJSON.utf8) : nil
        }
    }

    /// One direction, one pattern and one `(startSec, pattern)` entry per day
    /// type. `datesJSON` is the pack's date table.
    private func lineJSON(
        datesJSON: String,
        starts: [[Int]],
        stops: [Int] = [111, 112, 113],
        arrivals: [Int] = [0, 120, 300],
        departures: [Int] = [30, 150, 330]
    ) -> String {
        let dayTypes = starts.map { dayType in
            "[" + dayType.map { "[\($0),0]" }.joined(separator: ",") + "]"
        }.joined(separator: ",")
        return """
        {"v":1,"mode":"metro","code":94,"name":"L9N","dates":{\(datesJSON)},\
        "directions":[{"id":0,"headsign":"Can Zam",\
        "patterns":[{"stops":\(stops),"arr":\(arrivals),"dep":\(departures)}],\
        "dayTypes":[\(dayTypes)]}]}
        """
    }

    /// Absolute instant of a wall-clock time in the pack's zone.
    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return calendar.date(from: components)!
    }

    // MARK: - Decoding

    func testDecodesIndexAndLine() throws {
        let pack = try metroPack(lineJSON: lineJSON(datesJSON: "\"20261030\":0", starts: [[36000]]))

        XCTAssertEqual(pack.timeZone.identifier, "Europe/Madrid")
        XCTAssertEqual(pack.feedVersion, "feed-1")
        XCTAssertEqual(pack.feedStart, "20261030")
        XCTAssertEqual(pack.feedEnd, "20261105")
        XCTAssertEqual(pack.fileName(mode: .metro, code: 94), "metro-94.json")

        let line = try XCTUnwrap(pack.line(mode: .metro, code: 94))
        XCTAssertEqual(line.mode, .metro)
        XCTAssertEqual(line.code, 94)
        XCTAssertEqual(line.name, "L9N")
        XCTAssertEqual(line.timeZone.identifier, "Europe/Madrid")
        XCTAssertEqual(line.directions.count, 1)
        XCTAssertEqual(line.directions[0].id, 0)
        XCTAssertEqual(line.directions[0].headsign, "Can Zam")
        XCTAssertEqual(line.directions[0].patterns[0].stops, [111, 112, 113])
        XCTAssertEqual(line.directions[0].patterns[0].arrivals, [0, 120, 300])
        XCTAssertEqual(line.directions[0].patterns[0].departures, [30, 150, 330])
        XCTAssertEqual(line.directions[0].dayTypes[0].map(\.start), [36000])
        XCTAssertNil(pack.line(mode: .bus, code: 94))
    }

    func testUnknownKeysAreTolerated() throws {
        let index = """
        {"v":1,"timezone":"Europe/Madrid","extra":"ignored","lines":[\
        {"mode":"metro","code":94,"name":"L9N","file":"metro-94.json","colour":"orange"}]}
        """
        let pack = try SchedulePack(index: Data(index.utf8)) { file in
            file == "metro-94.json"
                ? Data("""
                {"v":1,"mode":"metro","code":94,"name":"L9N","dates":{"20261030":0},\
                "directions":[{"id":0,"headsign":"Can Zam","extra":7,\
                "patterns":[{"stops":[1,2],"arr":[0,60],"dep":[0,90],"x":1}],\
                "dayTypes":[[[21600,0]]]}]}
                """.utf8)
                : nil
        }
        let line = try XCTUnwrap(pack.line(mode: .metro, code: 94))
        XCTAssertEqual(line.directions[0].patterns[0].stops, [1, 2])
        XCTAssertNil(pack.feedVersion)
        XCTAssertEqual(pack.feedStart, "")
    }

    func testUnsupportedVersionIsRejected() throws {
        let index = """
        {"v":2,"timezone":"Europe/Madrid","lines":[]}
        """
        XCTAssertThrowsError(try SchedulePack(index: Data(index.utf8)) { _ in nil })
    }

    // MARK: - Service day

    func testRunsUseTheDayTypeOfTheServiceDay() throws {
        let pack = try metroPack(lineJSON: lineJSON(
            datesJSON: "\"20261030\":0,\"20261031\":1",
            starts: [[36000], [43200]]
        ))
        let line = try XCTUnwrap(pack.line(mode: .metro, code: 94))

        let friday = line.runs(on: date(2026, 10, 30, 12), directionID: 0)
        XCTAssertEqual(friday.count, 1)
        XCTAssertEqual(friday[0].start, date(2026, 10, 30).addingTimeInterval(36_000))
        XCTAssertEqual(friday[0].end, date(2026, 10, 30).addingTimeInterval(36_270))
        XCTAssertEqual(friday[0].directionID, 0)
        XCTAssertEqual(friday[0].headsign, "Can Zam")

        let saturday = line.runs(on: date(2026, 10, 31, 12), directionID: 0)
        XCTAssertEqual(saturday.map(\.start), [date(2026, 10, 31).addingTimeInterval(43_200)])
    }

    func testDateWithoutServiceHasNoRuns() throws {
        let pack = try metroPack(lineJSON: lineJSON(datesJSON: "\"20261030\":0", starts: [[36000]]))
        let line = try XCTUnwrap(pack.line(mode: .metro, code: 94))

        XCTAssertTrue(line.runs(on: date(2026, 11, 2, 8), directionID: nil).isEmpty)
        XCTAssertTrue(line.arrivals(at: 111, directionID: 0, on: date(2026, 11, 2, 8)).isEmpty)
    }

    func testAfterMidnightRunOfThePreviousServiceDayIsIncluded() throws {
        // The Friday service day has a trip that leaves at 00:20 *after* its
        // own midnight, so it belongs to Friday's date but runs on Saturday.
        let pack = try metroPack(lineJSON: lineJSON(
            datesJSON: "\"20261030\":0,\"20261031\":1",
            starts: [[86_400 + 1_200], []]
        ))
        let line = try XCTUnwrap(pack.line(mode: .metro, code: 94))

        let saturdayRuns = line.runs(on: date(2026, 10, 31, 0, 30), directionID: 0)
        XCTAssertEqual(saturdayRuns.count, 1)
        XCTAssertEqual(saturdayRuns[0].start, date(2026, 10, 31, 0, 20))
        // It is still the previous day's trip: asking about Friday returns it.
        XCTAssertEqual(line.runs(on: date(2026, 10, 30, 23), directionID: 0).count, 1)
        // Saturday's own (empty) service day does not erase it.
        XCTAssertEqual(line.arrivals(at: 111, directionID: 0, on: date(2026, 10, 31, 0, 30)).count, 1)
        // Once the trip is over it is gone from the next day.
        XCTAssertTrue(line.runs(on: date(2026, 11, 1, 12), directionID: 0).isEmpty)
    }

    func testArrivalsAreSortedAbsoluteInstants() throws {
        let pack = try metroPack(lineJSON: lineJSON(
            datesJSON: "\"20261030\":0",
            starts: [[36_300, 36_000, 35_700]]
        ))
        let line = try XCTUnwrap(pack.line(mode: .metro, code: 94))

        let arrivals = line.arrivals(at: 113, directionID: 0, on: date(2026, 10, 30, 12))
        let midnight = date(2026, 10, 30)
        // `startSec` is the departure from the first stop and the offsets are
        // relative to its arrival, 30 s earlier.
        XCTAssertEqual(arrivals, [
            midnight.addingTimeInterval(35_700 - 30 + 300),
            midnight.addingTimeInterval(36_000 - 30 + 300),
            midnight.addingTimeInterval(36_300 - 30 + 300),
        ])
        // A stop the pattern does not serve has no arrivals at all.
        XCTAssertTrue(line.arrivals(at: 999, directionID: 0, on: date(2026, 10, 30, 12)).isEmpty)
        // A direction that does not exist has none either.
        XCTAssertTrue(line.arrivals(at: 113, directionID: 1, on: date(2026, 10, 30, 12)).isEmpty)
    }

    func testScheduledRunArrivalAtStop() throws {
        let pack = try metroPack(lineJSON: lineJSON(datesJSON: "\"20261030\":0", starts: [[36_000]]))
        let line = try XCTUnwrap(pack.line(mode: .metro, code: 94))
        let run = try XCTUnwrap(line.runs(on: date(2026, 10, 30, 12), directionID: 0).first)

        // `start` is the departure from the first stop; the offsets are
        // relative to its arrival, 30 s earlier.
        XCTAssertEqual(run.arrival(at: 111), date(2026, 10, 30).addingTimeInterval(35_970))
        XCTAssertEqual(run.arrival(at: 112), date(2026, 10, 30).addingTimeInterval(35_970 + 120))
        XCTAssertNil(run.arrival(at: 999))
    }

    func testStartIsAbsoluteAcrossTheAutumnDstChange() throws {
        // 2026-10-25 is the last Sunday of October: at 03:00 CEST the clock
        // goes back to 02:00 CET. The day has 25 hours, so a start that the
        // timetable puts 3 h 30 min after midnight is 02:30 CET, not 03:30.
        let pack = try metroPack(lineJSON: lineJSON(datesJSON: "\"20261025\":0", starts: [[12_600]]))
        let line = try XCTUnwrap(pack.line(mode: .metro, code: 94))
        let midnight = date(2026, 10, 25)
        let run = try XCTUnwrap(line.runs(on: date(2026, 10, 25, 12), directionID: 0).first)

        XCTAssertEqual(run.start.timeIntervalSince(midnight), 12_600, accuracy: 0.5)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        XCTAssertEqual(calendar.component(.hour, from: run.start), 2)
        let wallClock = try XCTUnwrap(calendar.date(bySettingHour: 3, minute: 30, second: 0, of: midnight))
        XCTAssertEqual(wallClock.timeIntervalSince(run.start), 3_600, accuracy: 0.5)
    }

    // MARK: - Cache

    func testArrivalsAreReusedWithinTheSameServiceDay() throws {
        let pack = try metroPack(lineJSON: lineJSON(datesJSON: "\"20261030\":0", starts: [[36_000]]))
        let line = try XCTUnwrap(pack.line(mode: .metro, code: 94))

        let first = line.arrivals(at: 112, directionID: 0, on: date(2026, 10, 30, 9))
        let second = line.arrivals(at: 112, directionID: 0, on: date(2026, 10, 30, 12))
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 1)
    }

    // MARK: - Head sign matching

    func testDirectionIsMatchedByHeadsignThenByStops() throws {
        let pack = try metroPack(lineJSON: """
        {"v":1,"mode":"metro","code":94,"name":"L9N","dates":{"20261030":0},\
        "directions":[\
        {"id":0,"headsign":"Can Zam","patterns":[{"stops":[111,112],"arr":[0,60],"dep":[0,90]}],\
        "dayTypes":[[[21600,0]]]},\
        {"id":1,"headsign":"La Sagrera","patterns":[{"stops":[113,112],"arr":[0,60],"dep":[0,90]}],\
        "dayTypes":[[[21600,0]]]}]\
        }
        """)
        let line = try XCTUnwrap(pack.line(mode: .metro, code: 94))

        // Case and accents do not matter.
        XCTAssertEqual(line.direction(headsign: "can zam", stopCodes: [])?.id, 0)
        // A headsign nobody uses falls back to the stops of the patterns.
        XCTAssertEqual(line.direction(headsign: "Desconegut", stopCodes: [113])?.id, 1)
        XCTAssertNil(line.direction(headsign: "Desconegut", stopCodes: []))
    }
}
