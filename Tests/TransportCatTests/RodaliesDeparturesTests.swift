import XCTest
@testable import TransportCat

/// Departure boards of a Rodalies station: the now filter, the day rollover, the
/// realtime delay and the scheduled/realtime label.
///
/// The pack fixture has two service dates (Thursday 2026-11-12 and Friday
/// 2026-11-13), one departure after midnight at Barcelona-Sants and one reverse
/// departure per line, which is exactly what the rules have to fold onto the
/// wall clock.
final class RodaliesDeparturesTests: XCTestCase {
    private func fixture(_ name: String, extension ext: String = "json") throws -> Data {
        #if os(Linux)
        guard let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures") else {
            XCTFail("Missing fixture \(name).\(ext)")
            throw RodaliesError.unexpectedPayload("missing fixture \(name)")
        }
        return try Data(contentsOf: url)
        #else
        guard let url = Bundle(for: RodaliesDeparturesTests.self).url(forResource: name, withExtension: ext) else {
            XCTFail("Missing fixture \(name).\(ext)")
            throw RodaliesError.unexpectedPayload("missing fixture \(name)")
        }
        return try Data(contentsOf: url)
        #endif
    }

    /// The pack fixture travels as base64 inside a JSON file: the test bundle
    /// would not carry a raw `.gz` as a resource. Decoding it is part of the
    /// test, so the gzip reader is exercised on real pack bytes.
    private func schedule() throws -> RodaliesSchedule {
        let wrapper = try JSONSerialization.jsonObject(with: try fixture("rodalies-schedule")) as? [String: Any]
        let base64 = try XCTUnwrap(wrapper?["gzipBase64"] as? String)
        let data = try XCTUnwrap(Data(base64Encoded: base64))
        return try XCTUnwrap(RodaliesClient.decodeSchedule(data), "the schedule fixture must decode")
    }

    /// A wall-clock instant in the timetable's timezone, which is what the board
    /// reads: the device timezone must not change the answers.
    private func madrid(
        _ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int
    ) throws -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Madrid"))
        return try XCTUnwrap(Calendar(identifier: .gregorian).date(from: components))
    }

    // MARK: - Order and labels

    func testBoardIsSortedAndLabelledAsScheduledWhenTheFeedIsSilent() throws {
        let now = try madrid(2026, 11, 13, 5, 50)
        let board = RodaliesDepartures.nextDepartures(
            stationID: "71801",
            now: now,
            schedule: try schedule()
        )
        XCTAssertEqual(board.map(\.lineCode), ["R1", "R1", "R16"])
        XCTAssertEqual(board.map(\.headsign), [
            "Barcelona-Passeig de Gràcia",
            "L'Hospitalet de Llobregat",
            "Vilanova i la Geltrú",
        ])
        XCTAssertEqual(board.map(\.direction), [0, 1, 0])
        XCTAssertEqual(board.map(\.tripID), [
            "5116V25731R1", "5116V25613R1", "5116V18122R16",
        ])
        // Without realtime data every row is the timetable, and says so.
        XCTAssertTrue(board.allSatisfy { !$0.isRealtime })
        XCTAssertTrue(board.allSatisfy { $0.delaySeconds == nil })
        XCTAssertEqual(board[0].expectedAt, board[0].scheduledAt)

        // 06:10, 07:10 and the after-midnight 24:10, which is tomorrow 00:10.
        XCTAssertEqual(board[0].scheduledAt, try madrid(2026, 11, 13, 6, 10))
        XCTAssertEqual(board[1].scheduledAt, try madrid(2026, 11, 13, 7, 10))
        XCTAssertEqual(board[2].scheduledAt, try madrid(2026, 11, 14, 0, 10))
    }

    func testOnlyDeparturesAheadOfNowAreListed() throws {
        let board = RodaliesDepartures.nextDepartures(
            stationID: "71801",
            now: try madrid(2026, 11, 13, 7, 5),
            schedule: try schedule()
        )
        XCTAssertEqual(board.map(\.tripID), ["5116V25613R1", "5116V18122R16"])
    }

    /// A departure whose scheduled time just passed but which is late is still a
    /// departure the rider can take; the board filters on the adjusted time.
    func testDelayKeepsALateTrainOnTheBoard() throws {
        let board = RodaliesDepartures.nextDepartures(
            stationID: "71801",
            now: try madrid(2026, 11, 13, 6, 15),
            schedule: try schedule(),
            delays: ["5116V25731R1": 600]
        )
        let delayed = try XCTUnwrap(board.first { $0.tripID == "5116V25731R1" })
        XCTAssertEqual(delayed.scheduledAt, try madrid(2026, 11, 13, 6, 10))
        XCTAssertEqual(delayed.delaySeconds, 600)
        XCTAssertEqual(delayed.expectedAt, try madrid(2026, 11, 13, 6, 20))
        XCTAssertTrue(delayed.isRealtime)
        // The board sorts by what the rider will actually see.
        XCTAssertEqual(board.first?.tripID, "5116V25731R1")
    }

    /// An early train whose adjusted time is already behind `now` is gone.
    func testEarlyTrainAlreadyGoneIsNotListed() throws {
        let board = RodaliesDepartures.nextDepartures(
            stationID: "71801",
            now: try madrid(2026, 11, 13, 6, 15),
            schedule: try schedule(),
            delays: ["5116V25731R1": -600]
        )
        XCTAssertFalse(board.contains { $0.tripID == "5116V25731R1" })
    }

    func testEveryDelayInTheFeedIsApplied() throws {
        let board = RodaliesDepartures.nextDepartures(
            stationID: "71801",
            now: try madrid(2026, 11, 13, 5, 50),
            schedule: try schedule(),
            delays: ["5116V25731R1": 0, "5116V25613R1": 3240, "5116V18122R16": 0]
        )
        XCTAssertEqual(board.map(\.tripID), ["5116V25731R1", "5116V25613R1", "5116V18122R16"])
        XCTAssertEqual(board.map(\.isRealtime), [true, true, true])
        XCTAssertEqual(board[1].expectedAt, try madrid(2026, 11, 13, 8, 4))
    }

    // MARK: - Day rollover

    /// At five past midnight today has no service of its own: the board is the
    /// after-midnight tail of yesterday's service day.
    func testAfterMidnightDepartureIsReadFromYesterday() throws {
        let now = try madrid(2026, 11, 14, 0, 5)
        let pack = try schedule()
        XCTAssertNil(pack.days["20261114"], "the fixture must not carry the 14th")

        let board = RodaliesDepartures.nextDepartures(stationID: "71801", now: now, schedule: pack)
        let departure = try XCTUnwrap(board.first)
        XCTAssertEqual(board.count, 1)
        XCTAssertEqual(departure.tripID, "5116V18122R16")
        XCTAssertEqual(departure.lineCode, "R16")
        XCTAssertEqual(departure.scheduledAt, try madrid(2026, 11, 14, 0, 10))
    }

    /// A pack downloaded before a feed reissue has no date for today; the board
    /// falls back to the newest date with the same weekday instead of staying
    /// empty.
    func testStalePackFallsBackToTheSameWeekday() throws {
        let pack = try schedule()
        let now = try madrid(2026, 11, 20, 5, 50)
        XCTAssertEqual(RodaliesDepartures.fallbackServiceDate(for: now, schedule: pack), "20261113")

        let board = RodaliesDepartures.nextDepartures(stationID: "71801", now: now, schedule: pack)
        XCTAssertEqual(board.map(\.tripID), ["5116V25731R1", "5116V25613R1", "5116V18122R16"])
        XCTAssertEqual(board.first?.scheduledAt, try madrid(2026, 11, 20, 6, 10))
    }

    // MARK: - Edges

    func testLimitCapsTheBoard() throws {
        let board = RodaliesDepartures.nextDepartures(
            stationID: "71801",
            now: try madrid(2026, 11, 13, 5, 50),
            schedule: try schedule(),
            limit: 2
        )
        XCTAssertEqual(board.count, 2)
    }

    func testStationWithoutDeparturesIsEmpty() throws {
        let board = RodaliesDepartures.nextDepartures(
            stationID: "00000",
            now: try madrid(2026, 11, 13, 5, 50),
            schedule: try schedule()
        )
        XCTAssertTrue(board.isEmpty)
    }

    func testDepartureIdentityIsStable() throws {
        let board = RodaliesDepartures.nextDepartures(
            stationID: "71801",
            now: try madrid(2026, 11, 13, 5, 50),
            schedule: try schedule()
        )
        XCTAssertEqual(Set(board.map(\.id)).count, board.count)
    }
}
