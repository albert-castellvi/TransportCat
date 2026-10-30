import XCTest
@testable import TransportCat

/// Tests for `TrainMotion`, the value type that smooths the markers between
/// polls (S4). Every train position comes from the real engine and a real
/// arrival, so the tests exercise the same shapes the app produces.
final class TrainMotionTests: XCTestCase {
    // Same synthetic line as TrainPositionEngineTests: three stations ~504.6 m
    // apart on a straight north-south polyline. Because the route is straight
    // and north-south, the distance the marker covers on screen equals the
    // distance it covers along the route, which makes the rate limit directly
    // measurable.
    private var stations: [Station] {
        [
            Station(code: 1, name: "Sud", orderInLine: 1, lineCode: "1", latitude: 41.34467731, longitude: 2.10724192, id: 81, accessible: true),
            Station(code: 2, name: "Mig", orderInLine: 2, lineCode: "1", latitude: 41.34921585, longitude: 2.10724192, id: 82, accessible: true),
            Station(code: 3, name: "Nord", orderInLine: 3, lineCode: "1", latitude: 41.35375440, longitude: 2.10724192, id: 83, accessible: true),
        ]
    }

    private var geometry: LineGeometry {
        LineGeometry(points: [
            GeoPoint(latitude: 41.34467731, longitude: 2.10724192),
            GeoPoint(latitude: 41.34592688, longitude: 2.10724192),
            GeoPoint(latitude: 41.34717644, longitude: 2.10724192),
            GeoPoint(latitude: 41.34842600, longitude: 2.10724192),
            GeoPoint(latitude: 41.34921585, longitude: 2.10724192),
            GeoPoint(latitude: 41.35072669, longitude: 2.10724192),
            GeoPoint(latitude: 41.35223754, longitude: 2.10724192),
            GeoPoint(latitude: 41.35375440, longitude: 2.10724192),
        ])
    }

    /// Fixed clock: every assertion uses explicit dates, never the wall clock.
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func makeEngine() throws -> TrainPositionEngine {
        try XCTUnwrap(TrainPositionEngine.make(stations: stations, geometry: geometry))
    }

    private func arrival(
        stationCode: Int = 2,
        destination: String = "Nord",
        seconds: Int,
        serviceCode: String? = "7",
        trajectCode: String? = "0011",
        via: Int? = 1
    ) -> Arrival {
        Arrival(
            stationCode: stationCode,
            lineCode: "1",
            destination: destination,
            seconds: seconds,
            rawText: "x",
            serviceCode: serviceCode,
            trajectCode: trajectCode,
            via: via
        )
    }

    /// Engine positions for one arrival at station 2, i.e. one train id.
    private func positions(_ engine: TrainPositionEngine, seconds: Int) -> [TrainPosition] {
        engine.positions(lineCode: "1", arrivals: [arrival(seconds: seconds)])
    }

    /// The marker never covers more than 24 m per second, whatever jump the
    /// poll would otherwise produce.
    func testStepPerSecondNeverExceedsTheRateLimit() throws {
        let engine = try makeEngine()
        var motion = TrainMotion()

        let slow = try XCTUnwrap(positions(engine, seconds: 120).first)
        motion.update(with: [slow], now: start)
        _ = motion.advance(to: start, engine: engine)

        // The next poll puts the target ~350 m ahead of the drawn marker.
        let ahead = try XCTUnwrap(positions(engine, seconds: 50).first)
        XCTAssertGreaterThan(ahead.routeDistance - slow.routeDistance, 300)
        motion.update(with: [ahead], now: start)

        var previous = try XCTUnwrap(motion.advance(to: start, engine: engine).first)
        XCTAssertEqual(previous.routeDistance, slow.routeDistance, accuracy: 1e-9)
        var largestStep = 0.0
        for second in 1...20 {
            let next = try XCTUnwrap(motion.advance(to: start.addingTimeInterval(Double(second)), engine: engine).first)
            let step = GeoMath.distanceMeters(from: previous.position, to: next.position)
            XCTAssertLessThanOrEqual(step, TrainMotion.maxStepMetersPerSecond + 0.001, "step at second \(second)")
            XCTAssertGreaterThanOrEqual(next.routeDistance, previous.routeDistance)
            largestStep = max(largestStep, step)
            previous = next
        }
        // The cap must be what limits the movement, not an idle marker.
        XCTAssertGreaterThan(largestStep, 20)
    }

    /// A target behind the drawn marker holds it in place: a forward train
    /// never moves backwards.
    func testForwardTrainNeverMovesBackwards() throws {
        let engine = try makeEngine()
        var motion = TrainMotion()

        let atStation = try XCTUnwrap(positions(engine, seconds: 30).first)
        motion.update(with: [atStation], now: start)
        let before = try XCTUnwrap(motion.advance(to: start, engine: engine).first)
        XCTAssertEqual(before.routeDistance, atStation.routeDistance, accuracy: 1e-9)

        // A new poll places the train early in the segment, 479 m behind the
        // station the marker already reached.
        let behind = try XCTUnwrap(positions(engine, seconds: 200).first)
        XCTAssertLessThan(behind.routeDistance, before.routeDistance - 100)
        motion.update(with: [behind], now: start)
        let after = try XCTUnwrap(motion.advance(to: start.addingTimeInterval(1), engine: engine).first)

        XCTAssertEqual(after.routeDistance, before.routeDistance, accuracy: 1e-9)
        XCTAssertEqual(after.position, before.position)
    }

    /// The marker waits at the station it is approaching instead of running
    /// past it.
    func testMarkerStopsAtTheApproachingStation() throws {
        let engine = try makeEngine()
        var motion = TrainMotion()

        let moving = try XCTUnwrap(positions(engine, seconds: 120).first)
        XCTAssertLessThan(moving.routeDistance, moving.segmentEndDistance)
        motion.update(with: [moving], now: start)
        _ = motion.advance(to: start, engine: engine)

        var last = try XCTUnwrap(motion.advance(to: start, engine: engine).first)
        for second in 1...120 {
            last = try XCTUnwrap(motion.advance(to: start.addingTimeInterval(Double(second)), engine: engine).first)
        }
        XCTAssertEqual(last.routeDistance, moving.segmentEndDistance, accuracy: 0.5)
        XCTAssertEqual(last.position.latitude, 41.34921585, accuracy: 0.0005)

        // Parked: a later tick does not move it.
        let parked = try XCTUnwrap(motion.advance(to: start.addingTimeInterval(121), engine: engine).first)
        XCTAssertEqual(parked.routeDistance, last.routeDistance, accuracy: 1e-6)
    }

    /// A train seen for the first time starts at the position the engine
    /// computed: there is nothing to ease from.
    func testNewTrainSnapsToItsComputedPosition() throws {
        let engine = try makeEngine()
        var motion = TrainMotion()

        let computed = try XCTUnwrap(positions(engine, seconds: 30).first)
        motion.update(with: [computed], now: start)
        let drawn = try XCTUnwrap(motion.advance(to: start, engine: engine).first)

        XCTAssertEqual(drawn.routeDistance, computed.routeDistance, accuracy: 1e-9)
        XCTAssertEqual(drawn.position, computed.position)
        XCTAssertEqual(drawn.id, computed.id)
    }

    /// A train the feed stopped reporting must disappear from the map.
    func testTrainMissingFromTheNextUpdateDisappears() throws {
        let engine = try makeEngine()
        var motion = TrainMotion()

        let arrivals = [
            arrival(stationCode: 2, seconds: 60, serviceCode: "7"),
            arrival(stationCode: 3, seconds: 120, serviceCode: "8"),
        ]
        let both = engine.positions(lineCode: "1", arrivals: arrivals)
        XCTAssertEqual(both.count, 2)

        motion.update(with: both, now: start)
        XCTAssertEqual(motion.advance(to: start, engine: engine).count, 2)

        motion.update(with: [try XCTUnwrap(both.first)], now: start)
        XCTAssertEqual(motion.advance(to: start.addingTimeInterval(1), engine: engine).count, 1)
    }

    /// Pure value type: the same calls with the same dates give the same
    /// result.
    func testSameInputsProduceTheSameOutput() throws {
        let engine = try makeEngine()
        let samples = [
            positions(engine, seconds: 120),
            positions(engine, seconds: 50),
            positions(engine, seconds: 20),
        ]

        func replay() -> [[TrainPosition]] {
            var motion = TrainMotion()
            var output: [[TrainPosition]] = []
            for (index, sample) in samples.enumerated() {
                let pollTime = start.addingTimeInterval(Double(index) * 20)
                motion.update(with: sample, now: pollTime)
                for tick in 1...5 {
                    output.append(motion.advance(to: pollTime.addingTimeInterval(Double(tick)), engine: engine))
                }
            }
            return output
        }

        XCTAssertEqual(replay(), replay())
    }
}
