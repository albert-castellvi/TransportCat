import XCTest
@testable import TransportCat

/// The trains a line should have, from its timetable alone (spec S5).
///
/// There is no L9N topology fixture in this repository, so the real-pack test
/// builds the stations and the geometry from the pack's own stop codes instead
/// of the TMB GeoJSON: it proves the pack decodes and yields running trains,
/// not that they sit on the real track. The synthetic line carries the
/// geometry-dependent assertions.
final class TheoreticalFleetTests: XCTestCase {
    private let timeZone = TimeZone(identifier: "Europe/Madrid")!

    // MARK: - Helpers

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
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

    /// Two stations ~500 m apart, north-south, with vertices between them.
    private var stations: [Station] {
        [
            Station(code: 1, name: "Sud", orderInLine: 1, lineCode: "94", latitude: 41.34467731, longitude: 2.10724192, id: 81, accessible: true),
            Station(code: 2, name: "Nord", orderInLine: 2, lineCode: "94", latitude: 41.34921585, longitude: 2.10724192, id: 82, accessible: true),
        ]
    }

    private var geometry: LineGeometry {
        LineGeometry(points: [
            GeoPoint(latitude: 41.34467731, longitude: 2.10724192),
            GeoPoint(latitude: 41.34592688, longitude: 2.10724192),
            GeoPoint(latitude: 41.34717644, longitude: 2.10724192),
            GeoPoint(latitude: 41.34842600, longitude: 2.10724192),
            GeoPoint(latitude: 41.34921585, longitude: 2.10724192),
        ])
    }

    private func engine(for stations: [Station], geometry: LineGeometry) throws -> TrainPositionEngine {
        try XCTUnwrap(TrainPositionEngine.make(stations: stations, geometry: geometry))
    }

    /// A pack of one metro line whose single direction runs `starts` (seconds
    /// from midnight) on 2026-10-30.
    private func line(
        stops: [Int],
        arrivals: [Int],
        departures: [Int],
        starts: [Int],
        code: Int = 94
    ) throws -> ScheduleLine {
        let startsJSON = starts.map { "[\($0),0]" }.joined(separator: ",")
        let index = """
        {"v":1,"timezone":"Europe/Madrid","lines":[\
        {"mode":"metro","code":\(code),"name":"L9N","file":"metro-\(code).json"}]}
        """
        let lineFile = """
        {"v":1,"mode":"metro","code":\(code),"name":"L9N","dates":{"20261030":0},\
        "directions":[{"id":0,"headsign":"Can Zam",\
        "patterns":[{"stops":\(stops),"arr":\(arrivals),"dep":\(departures)}],\
        "dayTypes":[[\(startsJSON)]]}]}
        """
        let pack = try SchedulePack(index: Data(index.utf8)) { file in
            file == "metro-\(code).json" ? Data(lineFile.utf8) : nil
        }
        return try XCTUnwrap(pack.line(mode: .metro, code: code))
    }

    // MARK: - Synthetic line

    func testTrainBetweenStationsIsInterpolatedInTime() throws {
        let line = try line(stops: [1, 2], arrivals: [0, 300], departures: [30, 330], starts: [21_600])
        let engine = try engine(for: stations, geometry: geometry)

        // The run leaves station 1 at 06:00:00 and reaches station 2 at
        // 06:04:30 (the offsets are relative to the first arrival, 05:59:30).
        let position = try XCTUnwrap(
            TheoreticalFleet.positions(
                line: line,
                stations: stations,
                engine: engine,
                now: date(2026, 10, 30, 6, 2, 15)
            ).first
        )

        XCTAssertEqual(position.id, "T0-21600")
        XCTAssertTrue(position.isTheoretical)
        XCTAssertTrue(position.forward)
        XCTAssertEqual(position.destination, "Can Zam")
        XCTAssertEqual(position.lineCode, "94")
        XCTAssertEqual(position.nextStationCode, 2)
        XCTAssertEqual(position.secondsToArrival, 135)
        XCTAssertEqual(position.segmentProgress, 0.5, accuracy: 0.0001)
        XCTAssertFalse(position.isDwelling)
        // Half of the segment: the marker is between the two station distances.
        let distances = engine.stationRouteDistances
        XCTAssertEqual(position.routeDistance, (distances[0] + distances[1]) / 2, accuracy: 0.5)
        XCTAssertEqual(position.segmentEndDistance, distances[1])
        XCTAssertEqual(position.heading, 0, accuracy: 0.5)
    }

    func testTrainDwellsAtTheStationBetweenArrivalAndDeparture() throws {
        let line = try line(stops: [1, 2], arrivals: [0, 300], departures: [30, 330], starts: [21_600])
        let engine = try engine(for: stations, geometry: geometry)

        let position = try XCTUnwrap(
            TheoreticalFleet.positions(
                line: line,
                stations: stations,
                engine: engine,
                now: date(2026, 10, 30, 5, 59, 45)
            ).first
        )

        XCTAssertTrue(position.isDwelling)
        XCTAssertEqual(position.nextStationCode, 1)
        XCTAssertEqual(position.secondsToArrival, 0)
        XCTAssertEqual(position.routeDistance, engine.stationRouteDistances[0], accuracy: 0.5)
        XCTAssertEqual(position.segmentEndDistance, engine.stationRouteDistances[0], accuracy: 0.5)
    }

    func testOnlyRunsInProgressAreReturned() throws {
        let line = try line(stops: [1, 2], arrivals: [0, 300], departures: [30, 330], starts: [21_600])
        let engine = try engine(for: stations, geometry: geometry)

        // Before the first arrival and after the last one there is no train.
        XCTAssertTrue(TheoreticalFleet.positions(
            line: line, stations: stations, engine: engine, now: date(2026, 10, 30, 5, 30)
        ).isEmpty)
        XCTAssertTrue(TheoreticalFleet.positions(
            line: line, stations: stations, engine: engine, now: date(2026, 10, 30, 6, 10)
        ).isEmpty)
        // On a date the pack has no service for, nothing runs either.
        XCTAssertTrue(TheoreticalFleet.positions(
            line: line, stations: stations, engine: engine, now: date(2026, 10, 31, 6, 2, 15)
        ).isEmpty)
    }

    func testEveryRunInProgressGetsAUniqueIdentity() throws {
        let line = try line(
            stops: [1, 2],
            arrivals: [0, 600],
            departures: [30, 630],
            starts: [21_600, 21_900, 22_200]
        )
        let engine = try engine(for: stations, geometry: geometry)

        let positions = TheoreticalFleet.positions(
            line: line,
            stations: stations,
            engine: engine,
            now: date(2026, 10, 30, 6, 5)
        )

        // A ten-minute trip every five minutes means two trains are on the line
        // at 06:05 (the 06:00 and the 06:05 one); the 06:10 one is not out yet.
        XCTAssertEqual(positions.map(\.id), ["T0-21600", "T0-21900"])
        XCTAssertEqual(Set(positions.map(\.id)).count, positions.count)
        XCTAssertTrue(positions.allSatisfy(\.isTheoretical))
    }

    func testBackwardPatternReportsTheReverseDirection() throws {
        let line = try line(stops: [2, 1], arrivals: [0, 300], departures: [30, 330], starts: [21_600])
        let engine = try engine(for: stations, geometry: geometry)

        let position = try XCTUnwrap(
            TheoreticalFleet.positions(
                line: line,
                stations: stations,
                engine: engine,
                now: date(2026, 10, 30, 6, 2, 15)
            ).first
        )

        XCTAssertFalse(position.forward)
        XCTAssertEqual(position.nextStationCode, 1)
        XCTAssertEqual(position.heading, 180, accuracy: 0.5)
    }

    func testRunWithAStopMissingFromTheLineIsSkipped() throws {
        let line = try line(stops: [1, 99], arrivals: [0, 300], departures: [30, 330], starts: [21_600])
        let engine = try engine(for: stations, geometry: geometry)

        XCTAssertTrue(TheoreticalFleet.positions(
            line: line,
            stations: stations,
            engine: engine,
            now: date(2026, 10, 30, 6, 2, 15)
        ).isEmpty)
    }

    // MARK: - Real pack

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

    func testRealL9NPackYieldsRunningTrains() throws {
        let index = try fixture("schedule/index")
        let pack = try SchedulePack(index: index) { file in
            try? self.fixture("schedule/" + (file as NSString).deletingPathExtension)
        }
        let line = try XCTUnwrap(pack.line(mode: .metro, code: 94))

        // Stations and geometry built from the pack itself: the stop codes are
        // the real ones, the coordinates are a straight line in their order.
        let pattern = try XCTUnwrap(line.directions[0].patterns.first)
        let stations = pattern.stops.enumerated().map { index, code in
            Station(
                code: code,
                name: "Estació \(code)",
                orderInLine: index + 1,
                lineCode: "94",
                latitude: 41.40 + Double(index) * 0.005,
                longitude: 2.19,
                id: nil,
                accessible: nil
            )
        }
        let geometry = LineGeometry(points: stations.map {
            GeoPoint(latitude: $0.latitude, longitude: $0.longitude)
        })
        let engine = try engine(for: stations, geometry: geometry)

        let positions = TheoreticalFleet.positions(
            line: line,
            stations: stations,
            engine: engine,
            now: date(2026, 10, 30, 11, 0)
        )

        XCTAssertFalse(positions.isEmpty, "L9N must have trains at 11:00 on a service day")
        XCTAssertEqual(Set(positions.map(\.id)).count, positions.count)
        XCTAssertTrue(positions.allSatisfy(\.isTheoretical))
        XCTAssertTrue(positions.allSatisfy { $0.lineCode == "94" })
        let total = try XCTUnwrap(engine.stationRouteDistances.last)
        for position in positions {
            XCTAssertGreaterThanOrEqual(position.routeDistance, 0)
            XCTAssertLessThanOrEqual(position.routeDistance, total)
            XCTAssertTrue(position.heading.isFinite)
            XCTAssertNotNil(engine.point(atRouteDistance: position.routeDistance))
        }
    }
}
