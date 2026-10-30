import XCTest
@testable import TransportCat

/// Bus delay against the timetable (spec S4): the match, its ambiguity rule and
/// the confidence levels, then the same estimator on the real H12 pack with a
/// captured iBus snapshot.
final class BusDelayTests: XCTestCase {
    private let timeZone = TimeZone(identifier: "Europe/Madrid")!
    /// A Friday, inside the fixture pack's date range, at 08:00 local time.
    private var now: Date { date(2026, 10, 30, 8, 0) }

    // MARK: - Helpers

    private struct PatternSpec {
        let stops: [Int]
        let arrivals: [Int]
        let departures: [Int]
    }

    /// The full H12 route in one direction: four stops, five minutes apart.
    private var fullPattern: PatternSpec {
        PatternSpec(
            stops: [10, 20, 30, 40],
            arrivals: [0, 300, 600, 900],
            departures: [30, 330, 630, 930]
        )
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
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

    /// A bus pack of one line (212, H12) and one direction, whose day type 0 is
    /// 2026-10-30.
    private func line(
        patterns: [PatternSpec],
        starts: [(start: Int, pattern: Int)]
    ) throws -> ScheduleLine {
        let patternsJSON = patterns.map { pattern in
            """
            {"stops":\(pattern.stops),"arr":\(pattern.arrivals),"dep":\(pattern.departures)}
            """
        }.joined(separator: ",")
        let startsJSON = starts.map { "[\($0.start),\($0.pattern)]" }.joined(separator: ",")
        let index = """
        {"v":1,"timezone":"Europe/Madrid","lines":[\
        {"mode":"bus","code":212,"name":"H12","file":"bus-212.json"}]}
        """
        let lineFile = """
        {"v":1,"mode":"bus","code":212,"name":"H12","dates":{"20261030":0},\
        "directions":[{"id":0,"headsign":"Gornal","patterns":[\(patternsJSON)],\
        "dayTypes":[[\(startsJSON)]]}]}
        """
        let pack = try SchedulePack(index: Data(index.utf8)) { file in
            file == "bus-212.json" ? Data(lineFile.utf8) : nil
        }
        return try XCTUnwrap(pack.line(mode: .bus, code: 212))
    }

    /// A bus every ten minutes from 06:00, so the headway is 600 s.
    private func tenMinuteLine() throws -> ScheduleLine {
        try line(
            patterns: [fullPattern],
            starts: (0..<100).map { (start: 21_600 + 600 * $0, pattern: 0) }
        )
    }

    /// Observations of one run, every stop of the pattern shifted by `delay`.
    private func observations(
        of run: ScheduledRun,
        stops: [Int],
        delay: TimeInterval
    ) -> [(stopCode: Int, eta: Date)] {
        stops.compactMap { stop in
            guard let arrival = run.arrival(at: stop) else { return nil }
            return (stopCode: stop, eta: arrival.addingTimeInterval(delay))
        }
    }

    /// The run of the day closest to `now`, which is the one a bus at `now`
    /// belongs to.
    private func currentRun(_ line: ScheduleLine) throws -> ScheduledRun {
        try XCTUnwrap(line.runs(on: now, directionID: 0).min {
            abs($0.originArrival.timeIntervalSince(now)) < abs($1.originArrival.timeIntervalSince(now))
        })
    }

    // MARK: - Matching

    func testOnTimeBusIsHighConfidence() throws {
        let line = try tenMinuteLine()
        let run = try currentRun(line)

        let estimate = BusDelay.estimate(
            observations: observations(of: run, stops: [10, 20, 30, 40], delay: 0),
            line: line,
            directionID: 0,
            now: now
        )

        let result = try XCTUnwrap(estimate)
        XCTAssertEqual(result.seconds, 0)
        XCTAssertEqual(result.confidence, .high)
        XCTAssertEqual(result.scheduledArrival, run.arrival(at: 10))
    }

    func testThreeMinutesLateIsMediumConfidence() throws {
        let line = try tenMinuteLine()
        let run = try currentRun(line)

        let estimate = try XCTUnwrap(BusDelay.estimate(
            observations: observations(of: run, stops: [10, 20, 30, 40], delay: 180),
            line: line,
            directionID: 0,
            now: now
        ))

        // Four stops agreeing within a second, but 3 min against a 10 min
        // headway is not the "headway >= 4x delay" case, so not high.
        XCTAssertEqual(estimate.seconds, 180)
        XCTAssertEqual(estimate.confidence, .medium)
    }

    func testEarlyBusIsNegative() throws {
        let line = try tenMinuteLine()
        let run = try currentRun(line)

        let estimate = try XCTUnwrap(BusDelay.estimate(
            observations: observations(of: run, stops: [10, 20, 30], delay: -120),
            line: line,
            directionID: 0,
            now: now
        ))

        XCTAssertEqual(estimate.seconds, -120)
        // 10 min of headway is at least four times 2 min, so this one is solid.
        XCTAssertEqual(estimate.confidence, .high)
    }

    func testDelayNearHalfTheHeadwayIsLowConfidence() throws {
        let line = try tenMinuteLine()
        let run = try currentRun(line)

        let estimate = try XCTUnwrap(BusDelay.estimate(
            observations: observations(of: run, stops: [10, 20, 30, 40], delay: 260),
            line: line,
            directionID: 0,
            now: now
        ))

        // 260 s is under half the 600 s headway (so not ambiguous) but under
        // neither confidence ratio.
        XCTAssertEqual(estimate.seconds, 260)
        XCTAssertEqual(estimate.confidence, .low)
    }

    func testStopsThatDisagreeAreNotABus() throws {
        let line = try tenMinuteLine()
        let run = try currentRun(line)
        let onTime = run.arrival(at: 10)!
        let skewed = run.arrival(at: 20)!.addingTimeInterval(150)

        // The same bus cannot be on time at one stop and 150 s off at the next:
        // no run fits both, so there is no estimate at all.
        let estimate = BusDelay.estimate(
            observations: [(stopCode: 10, eta: onTime), (stopCode: 20, eta: skewed)],
            line: line,
            directionID: 0,
            now: now
        )

        XCTAssertNil(estimate)
    }

    func testDelayOverHalfTheHeadwayIsAmbiguous() throws {
        // Short turns at the origin make the line's headway there 5 min, while
        // the observed stop is only served by the every-30-min full runs. A
        // 200 s offset is then more than half a headway away: the run cannot be
        // identified.
        var starts: [(start: Int, pattern: Int)] = []
        for index in 0..<30 {
            let full = 21_600 + 1_800 * index
            starts.append((start: full, pattern: 0))
            for offset in stride(from: 300, to: 1_800, by: 300) {
                starts.append((start: full + offset, pattern: 1))
            }
        }
        let shortTurn = PatternSpec(stops: [10], arrivals: [0], departures: [30])
        let line = try line(patterns: [fullPattern, shortTurn], starts: starts)
        let fullRuns = line.runs(on: now, directionID: 0).filter { $0.pattern.stops.count == 4 }
        let run = try XCTUnwrap(fullRuns.min {
            abs($0.originArrival.timeIntervalSince(now)) < abs($1.originArrival.timeIntervalSince(now))
        })

        XCTAssertNil(BusDelay.estimate(
            observations: observations(of: run, stops: [30], delay: 200),
            line: line,
            directionID: 0,
            now: now
        ))
        // A offset the headway does explain is still reported.
        let plausible = try XCTUnwrap(BusDelay.estimate(
            observations: observations(of: run, stops: [30], delay: 120),
            line: line,
            directionID: 0,
            now: now
        ))
        XCTAssertEqual(plausible.seconds, 120)
    }

    func testNoObservationsMeansNoEstimate() throws {
        let line = try tenMinuteLine()
        XCTAssertNil(BusDelay.estimate(observations: [], line: line, directionID: 0, now: now))
    }

    // MARK: - Real data

    /// Reads a fixture from the repository, so the test does not depend on how
    /// Xcode copies the folder into the test bundle (and works when the build
    /// reaches this file through a symlink).
    private func fixture(_ path: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(path + ".json")
        return try Data(contentsOf: url)
    }

    /// Moves an instant onto one service date of the pack, keeping its local
    /// time of day, so a captured snapshot can be compared with any week of the
    /// timetable. A date with the same weekday is preferred: it has the same
    /// kind of service.
    private func shift(_ instant: Date, onto dates: [String: Int]) throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let captured = calendar.dateComponents([.hour, .minute, .second, .weekday], from: instant)
        let keys = dates.keys.sorted()
        let target = try XCTUnwrap(keys.first { key in
            guard let midnight = midnight(of: key, calendar: calendar) else { return false }
            return calendar.component(.weekday, from: midnight) == captured.weekday
        } ?? keys.first)
        let day = try XCTUnwrap(midnight(of: target, calendar: calendar))
        var components = calendar.dateComponents([.year, .month, .day], from: day)
        components.hour = captured.hour
        components.minute = captured.minute
        components.second = captured.second
        return try XCTUnwrap(calendar.date(from: components))
    }

    private func midnight(of key: String, calendar: Calendar) -> Date? {
        guard key.count == 8,
              let year = Int(key.prefix(4)),
              let month = Int(key.dropFirst(4).prefix(2)),
              let day = Int(key.suffix(2)) else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        return calendar.date(from: components)
    }

    /// The real H12 pack against the captured iBus snapshot: the buses of the
    /// snapshot are matched to the timetable of the same time of day, and every
    /// estimate stays inside the half-headway the ambiguity rule allows.
    func testRealH12SnapshotProducesSaneEstimates() throws {
        let index = try fixture("schedule/index")
        let pack = try SchedulePack(index: index) { file in
            try? self.fixture("schedule/" + (file as NSString).deletingPathExtension)
        }
        let line = try XCTUnwrap(pack.line(mode: .bus, code: 212))

        let root = try XCTUnwrap(JSONValue.dictionary(from: try JSONSerialization.jsonObject(with: fixture("ibus-H12-snapshot"))))
        let capturedMillis = try XCTUnwrap(JSONValue.int(from: root["captured_at"]))
        let captured = Date(timeIntervalSince1970: Double(capturedMillis) / 1000)
        let at = try shift(captured, onto: line.dates)

        // Observations grouped by bus, exactly as the poll builds them: the
        // stop it was seen at, the instant it is expected there, and the
        // destination that identifies its direction.
        var stopsByBus: [Int: [(stopCode: Int, eta: Date)]] = [:]
        var destinationsByBus: [Int: String] = [:]
        for (stopKey, stop) in try XCTUnwrap(JSONValue.dictionary(from: root["stops"])) {
            let stopCode = try XCTUnwrap(Int(stopKey))
            let entry = try XCTUnwrap(JSONValue.dictionary(from: stop))
            for trajecte in JSONValue.array(from: entry["linies_trajectes"]) ?? [] {
                let dict = try XCTUnwrap(JSONValue.dictionary(from: trajecte))
                let destination = try XCTUnwrap(JSONValue.string(from: dict["desti_trajecte"]))
                for bus in JSONValue.array(from: dict["propers_busos"]) ?? [] {
                    let busDict = try XCTUnwrap(JSONValue.dictionary(from: bus))
                    let busID = try XCTUnwrap(JSONValue.int(from: busDict["id_bus"]))
                    let arrivalMillis = try XCTUnwrap(JSONValue.int(from: busDict["temps_arribada"]))
                    let eta = at.addingTimeInterval(Double(arrivalMillis - capturedMillis) / 1000)
                    stopsByBus[busID, default: []].append((stopCode: stopCode, eta: eta))
                    destinationsByBus[busID] = destination
                }
            }
        }
        XCTAssertFalse(stopsByBus.isEmpty)

        var estimates: [Int: DelayEstimate] = [:]
        for (busID, observations) in stopsByBus {
            let destination = try XCTUnwrap(destinationsByBus[busID])
            let direction = try XCTUnwrap(
                line.direction(headsign: destination, stopCodes: Set(observations.map(\.stopCode))),
                "no scheduled direction for \(destination)"
            )
            if let estimate = BusDelay.estimate(
                observations: observations,
                line: line,
                directionID: direction.id,
                now: at
            ) {
                estimates[busID] = estimate
            }
        }

        XCTAssertGreaterThanOrEqual(estimates.count, 2, "the snapshot must yield several estimates")
        for (busID, estimate) in estimates {
            let destination = try XCTUnwrap(destinationsByBus[busID])
            let direction = try XCTUnwrap(line.direction(
                headsign: destination,
                stopCodes: Set(stopsByBus[busID]!.map(\.stopCode))
            ))
            // The line frequency around the capture: the headway the delay is
            // only identifiable against.
            let starts = line.runs(on: at, directionID: direction.id)
                .map(\.start)
                .filter { $0 >= at.addingTimeInterval(-600) && $0 <= at.addingTimeInterval(1_800) }
            let headway = try XCTUnwrap(Regularity.medianHeadway(of: starts))
            XCTAssertLessThanOrEqual(
                abs(estimate.seconds),
                Int(headway / 2),
                "bus \(busID) is \(estimate.seconds) s off against a \(Int(headway)) s headway"
            )
        }
    }
}
