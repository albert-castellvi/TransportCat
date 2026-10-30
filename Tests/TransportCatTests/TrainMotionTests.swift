import XCTest
@testable import TransportCat

/// Tests for `TrainMotion`, the value type that smooths the markers between
/// polls (S1). Every train position comes from the real engine and a real
/// arrival, so the tests exercise the same shapes the app produces.
final class TrainMotionTests: XCTestCase {
    // Same synthetic line as TrainPositionEngineTests: three stations ~504.6 m
    // apart on a straight north-south polyline. Because the route is straight
    // and north-south, the distance the marker covers on screen equals the
    // distance it covers along the route, which makes the velocity limits
    // directly measurable from consecutive positions.
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

    /// Tick the app's ticker uses between polls: 10 Hz (S1).
    private let tick = 0.1

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

    /// The engine position whose route distance is closest to `distance`.
    ///
    /// A real poll can only place a train on the discrete points the countdown
    /// formula derives, so the tests move the target with one of those instead
    /// of inventing an arbitrary distance.
    private func poll(_ engine: TrainPositionEngine, nearestTo distance: Double) -> TrainPosition? {
        var best: TrainPosition?
        for seconds in 1...300 {
            guard let candidate = positions(engine, seconds: seconds).first else { continue }
            if let current = best,
               abs(current.routeDistance - distance) <= abs(candidate.routeDistance - distance) {
                continue
            }
            best = candidate
        }
        return best
    }

    /// S1: the whole point of the velocity controller. Speed never exceeds
    /// `maxVelocity`, the speed never changes faster than the acceleration
    /// limit allows, the marker never walks backwards, never crosses the
    /// platform and ends parked on it.
    ///
    /// The window is 300 ticks of 0.1 s (the real ticker rate) and contains
    /// both kinds of poll the feed produces: one that moves the target ~120 m
    /// ahead (catch-up acceleration) and one that moves it ~60 m behind (the
    /// marker has to brake and wait instead of jumping back).
    func testSpeedNeverExceedsTheLimits() throws {
        // The spec's controller constants (S1). Pinned here because every
        // limit below is expressed through them.
        XCTAssertEqual(TrainMotion.velocityGain, 0.1)
        XCTAssertEqual(TrainMotion.maxVelocity, 12)
        XCTAssertEqual(TrainMotion.brakingDeceleration, 2)
        XCTAssertEqual(TrainMotion.maxAcceleration, 4)
        XCTAssertEqual(TrainMotion.snapThresholdMeters, 1500)

        let engine = try makeEngine()
        var motion = TrainMotion()

        // Mid-segment, so there is room to accelerate, brake and park.
        let initial = try XCTUnwrap(positions(engine, seconds: 50).first)
        XCTAssertLessThan(initial.routeDistance, initial.segmentEndDistance)
        motion.update(with: [initial], now: start)

        var previous = try XCTUnwrap(motion.advance(to: start, engine: engine).first)
        XCTAssertEqual(previous.routeDistance, initial.routeDistance, accuracy: 1e-9)
        // A fresh marker moves at the engine speed.
        var previousSpeed = engine.speed
        var largestSpeed = 0.0

        for step in 1...300 {
            let now = start.addingTimeInterval(Double(step) * tick)

            if step == 20 {
                let ahead = try XCTUnwrap(poll(engine, nearestTo: previous.routeDistance + 120))
                XCTAssertGreaterThan(ahead.routeDistance - previous.routeDistance, 100, "poll must move the target ahead")
                motion.update(with: [ahead], now: now)
            }
            if step == 70 {
                let behind = try XCTUnwrap(poll(engine, nearestTo: previous.routeDistance - 60))
                XCTAssertLessThan(behind.routeDistance, previous.routeDistance - 40, "poll must move the target behind")
                motion.update(with: [behind], now: now)
            }

            let next = try XCTUnwrap(motion.advance(to: now, engine: engine).first)
            let covered = GeoMath.distanceMeters(from: previous.position, to: next.position)
            let speed = covered / tick

            XCTAssertLessThanOrEqual(speed, TrainMotion.maxVelocity + 0.01, "speed at step \(step)")
            XCTAssertGreaterThanOrEqual(next.routeDistance, previous.routeDistance - 1e-9, "walked backwards at step \(step)")
            XCTAssertLessThanOrEqual(next.routeDistance, next.segmentEndDistance + 1e-9, "crossed the platform at step \(step)")

            // Acceleration limit, in m/s per step, with no exception: the brake
            // curve is gentler than the limit, so even the stop at the
            // platform is smooth (measured on live data: peak 4.00 m/s2).
            let speedChange = abs(speed - previousSpeed)
            XCTAssertLessThanOrEqual(speedChange, TrainMotion.maxAcceleration * tick + 0.05, "abrupt speed change at step \(step)")

            largestSpeed = max(largestSpeed, speed)
            previousSpeed = speed
            previous = next
        }

        // The catch-up phase must actually use the speed cap, and the brake
        // phase must come back down from it.
        XCTAssertEqual(largestSpeed, TrainMotion.maxVelocity, accuracy: 0.05)
        // Parked on the platform it was approaching, not before it and not
        // past it.
        XCTAssertEqual(previous.routeDistance, previous.segmentEndDistance, accuracy: 1e-9)
        let parked = try XCTUnwrap(motion.advance(to: start.addingTimeInterval(301 * tick), engine: engine).first)
        XCTAssertEqual(parked.routeDistance, previous.routeDistance, accuracy: 1e-6)
        XCTAssertEqual(parked.position, previous.position)
    }

    /// A target behind the drawn marker brakes it to a stop in place: a
    /// forward train never moves backwards.
    func testForwardTrainNeverMovesBackwards() throws {
        try assertForwardTrainNeverMovesBackwards(tick: 1)
    }

    /// Same rule at the 10 Hz tick the app uses: more, smaller steps must not
    /// make the marker creep backwards either.
    func testForwardTrainNeverMovesBackwardsAtTenthSecondTicks() throws {
        try assertForwardTrainNeverMovesBackwards(tick: tick)
    }

    private func assertForwardTrainNeverMovesBackwards(tick: Double) throws {
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
        let after = try XCTUnwrap(motion.advance(to: start.addingTimeInterval(tick), engine: engine).first)
        XCTAssertEqual(after.routeDistance, before.routeDistance, accuracy: 1e-9)
        XCTAssertEqual(after.position, before.position)

        // Still held over the following ticks: the marker waits for a poll
        // that overtakes it instead of reversing.
        for step in 2...20 {
            let later = try XCTUnwrap(motion.advance(to: start.addingTimeInterval(Double(step) * tick), engine: engine).first)
            XCTAssertEqual(later.routeDistance, before.routeDistance, accuracy: 1e-9, "tick \(step)")
            XCTAssertEqual(later.position, before.position)
        }
    }

    /// The marker waits at the station it is approaching instead of running
    /// past it.
    func testMarkerStopsAtTheApproachingStation() throws {
        try assertMarkerStopsAtTheApproachingStation(tick: 1)
    }

    /// Same rule at the 10 Hz tick: 1200 small steps must end on the platform
    /// instead of somewhere in the 300 m buffer.
    func testMarkerStopsAtTheApproachingStationAtTenthSecondTicks() throws {
        try assertMarkerStopsAtTheApproachingStation(tick: tick)
    }

    private func assertMarkerStopsAtTheApproachingStation(tick: Double) throws {
        let engine = try makeEngine()
        var motion = TrainMotion()

        let moving = try XCTUnwrap(positions(engine, seconds: 120).first)
        XCTAssertLessThan(moving.routeDistance, moving.segmentEndDistance)
        motion.update(with: [moving], now: start)
        _ = motion.advance(to: start, engine: engine)

        // 120 s of travel is plenty for the ~479 m left at the engine speed.
        let ticks = Int((120 / tick).rounded())
        var last = try XCTUnwrap(motion.advance(to: start, engine: engine).first)
        for step in 1...ticks {
            last = try XCTUnwrap(motion.advance(to: start.addingTimeInterval(Double(step) * tick), engine: engine).first)
            XCTAssertLessThanOrEqual(last.routeDistance, last.segmentEndDistance + 1e-9, "crossed the station at tick \(step)")
        }
        XCTAssertEqual(last.routeDistance, moving.segmentEndDistance, accuracy: 0.5)
        XCTAssertEqual(last.position.latitude, 41.34921585, accuracy: 0.0005)

        // Parked: a later tick does not move it.
        let parked = try XCTUnwrap(motion.advance(to: start.addingTimeInterval(Double(ticks + 1) * tick), engine: engine).first)
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

    /// S2: the published heading belongs to the drawn point, not to the poll.
    /// The marker eases between polls, so its bearing is recomputed at the
    /// displayed distance and in the travel direction.
    func testAdvancedHeadingMatchesTheEngineHeadingAtTheDisplayedDistance() throws {
        let engine = try makeEngine()
        var motion = TrainMotion()

        let ahead = try XCTUnwrap(positions(engine, seconds: 50).first)
        motion.update(with: [ahead], now: start)
        _ = motion.advance(to: start, engine: engine)

        // A poll that drops the target far behind forces the marker to ease
        // instead of snapping, so the drawn distance moves between polls.
        let slow = try XCTUnwrap(positions(engine, seconds: 200).first)
        motion.update(with: [slow], now: start)

        var drawnDistances: Set<Double> = []
        for step in 1...50 {
            let drawn = try XCTUnwrap(motion.advance(to: start.addingTimeInterval(Double(step) * tick), engine: engine).first)
            let expected = engine.heading(atRouteDistance: drawn.routeDistance, forward: drawn.forward)
            XCTAssertEqual(drawn.heading, expected, accuracy: 1e-9, "step \(step)")
            XCTAssertGreaterThanOrEqual(drawn.heading, 0)
            XCTAssertLessThan(drawn.heading, 360)
            drawnDistances.insert(drawn.routeDistance)
        }
        XCTAssertGreaterThan(drawnDistances.count, 1)
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
                for step in 1...50 {
                    output.append(motion.advance(to: pollTime.addingTimeInterval(Double(step) * tick), engine: engine))
                }
            }
            return output
        }

        XCTAssertEqual(replay(), replay())
    }
}
