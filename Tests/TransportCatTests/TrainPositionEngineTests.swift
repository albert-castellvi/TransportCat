import XCTest
@testable import TransportCat

final class TrainPositionEngineTests: XCTestCase {
    // Synthetic straight line: three stations, ~504.6 m apart, along a
    // north-south polyline with intermediate vertices between stations.
    // Station order 1,2,3 = south to north (latitudes increasing).
    private var stations: [Station] {
        [
            Station(code: 1, name: "Sud", orderInLine: 1, lineCode: "1", latitude: 41.34467731, longitude: 2.10724192, id: 81, accessible: true),
            Station(code: 2, name: "Mig", orderInLine: 2, lineCode: "1", latitude: 41.34921585, longitude: 2.10724192, id: 82, accessible: true),
            Station(code: 3, name: "Nord", orderInLine: 3, lineCode: "1", latitude: 41.35375440, longitude: 2.10724192, id: 83, accessible: true),
        ]
    }

    private var geometry: LineGeometry {
        // Vertices every ~125 m so stations sit on vertices.
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

    // Sparse polyline: the whole route is one ~2.2 km segment with no vertex
    // between the stations, like the live TMB geometry (BUG-2). Both stations
    // are closer to the FIRST vertex, which is what collapsed them onto the
    // same vertex before the fix.
    private var sparseStations: [Station] {
        [
            Station(code: 11, name: "South", orderInLine: 1, lineCode: "1", latitude: 41.34360000, longitude: 2.10724192, id: 91, accessible: true),
            Station(code: 12, name: "North", orderInLine: 2, lineCode: "1", latitude: 41.34900000, longitude: 2.10724192, id: 92, accessible: true),
        ]
    }

    private var sparseGeometry: LineGeometry {
        LineGeometry(points: [
            GeoPoint(latitude: 41.34000000, longitude: 2.10724192),
            GeoPoint(latitude: 41.36000000, longitude: 2.10724192),
        ])
    }

    private func makeEngine(speed: Double = TrainPositionEngine.defaultSpeedMetersPerSecond) throws -> TrainPositionEngine {
        try XCTUnwrap(TrainPositionEngine.make(stations: stations, geometry: geometry, speedMetersPerSecond: speed))
    }

    /// One arrival at station 2 of the synthetic line. `serviceCode` and
    /// `trajectCode` default to one identifiable train.
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

    func testSegmentLengthIsDistanceBetweenStations() throws {
        let engine = try makeEngine()
        // 55 s of countdown over a 63 s segment at the default 8 m/s is half
        // the segment already covered.
        let position = try XCTUnwrap(engine.positions(lineCode: "1", arrivals: [arrival(seconds: 55)]).first)

        XCTAssertTrue(position.forward)
        XCTAssertEqual(position.segmentProgress, 0.5, accuracy: 0.01)
        // Midpoint latitude between station 1 and 2.
        XCTAssertEqual(position.position.latitude, 41.34694658, accuracy: 0.0005)
        // Longitude unchanged on this straight north-south line.
        XCTAssertEqual(position.position.longitude, 2.10724192, accuracy: 1e-6)
        // What the smoother needs: the station being approached, and a drawn
        // point halfway along the segment.
        XCTAssertEqual(position.segmentEndDistance, 504.6, accuracy: 1.0)
        XCTAssertEqual(position.routeDistance, position.segmentEndDistance / 2, accuracy: 5)
        XCTAssertFalse(position.isDwelling)
    }

    func testStationsProjectOntoSegmentWhenPolylineIsSparse() throws {
        // Both stations sit on one vertex-less 2.2 km segment and are ~600 m
        // apart. Nearest VERTEX projection snapped both to the same (first)
        // vertex and reported a 0 m segment: the train stayed pinned at
        // progress 0 and then jumped. Segment projection must report the real
        // along-route distance instead.
        let speed = TrainPositionEngine.defaultSpeedMetersPerSecond
        let engine = try XCTUnwrap(
            TrainPositionEngine.make(stations: sparseStations, geometry: sparseGeometry, speedMetersPerSecond: speed)
        )
        let routeSegment = GeoMath.distanceMeters(
            from: GeoPoint(latitude: 41.34360000, longitude: 2.10724192),
            to: GeoPoint(latitude: 41.34900000, longitude: 2.10724192)
        )
        XCTAssertEqual(routeSegment, 600, accuracy: 5)

        // 60 s of countdown on the 75 s segment: half of it already covered.
        let arrival = Arrival(stationCode: 12, lineCode: "1", destination: "North", seconds: 60, rawText: "1 min")
        let position = try XCTUnwrap(engine.positions(lineCode: "1", arrivals: [arrival]).first)

        XCTAssertEqual(position.segmentProgress, 0.5, accuracy: 0.02)
        // Drawn between the two stations, not pinned on either of them.
        XCTAssertGreaterThan(position.position.latitude, 41.34360000)
        XCTAssertLessThan(position.position.latitude, 41.34900000)
        XCTAssertEqual(position.position.latitude, 41.3463, accuracy: 0.0005)
    }

    func testDirectionBackwardTowardFirstStation() throws {
        let engine = try makeEngine()
        // No via: the destination name is the fallback direction source.
        let arrival = Arrival(stationCode: 2, lineCode: "1", destination: "Sud", seconds: 50, rawText: "x")
        let position = try XCTUnwrap(engine.positions(lineCode: "1", arrivals: [arrival]).first)

        XCTAssertFalse(position.forward)
        // Approaching station 2 from the north with a quarter of the segment
        // left, so three quarters of it are already covered (S8).
        XCTAssertEqual(position.segmentProgress, 0.75, accuracy: 0.02)
        // Close to station 2 (41.3492), not to station 3 (41.3538).
        XCTAssertEqual(position.position.latitude, 41.35035, accuracy: 0.0005)
    }

    func testFarFutureArrivalClampsToPreviousStation() throws {
        let engine = try makeEngine()
        // A countdown far beyond the segment duration would place the train
        // behind the station it just left; the ratio clamp holds it at 95% of
        // the segment remaining, i.e. 5% traveled.
        let position = try XCTUnwrap(engine.positions(lineCode: "1", arrivals: [arrival(seconds: 10_000)]).first)
        XCTAssertEqual(position.segmentProgress, 0.05, accuracy: 1e-9)
        XCTAssertEqual(position.position.latitude, 41.3449, accuracy: 0.0005)
    }

    func testNonNumericArrivalSkipped() throws {
        let engine = try makeEngine()
        let arrival = Arrival(stationCode: 2, lineCode: "1", destination: "Nord", seconds: nil, rawText: "Aprox.")
        XCTAssertTrue(engine.positions(lineCode: "1", arrivals: [arrival]).isEmpty)
    }

    func testUnknownStationCodeSkipped() throws {
        let engine = try makeEngine()
        let arrival = Arrival(stationCode: 999, lineCode: "1", destination: "Nord", seconds: 30, rawText: "x")
        XCTAssertTrue(engine.positions(lineCode: "1", arrivals: [arrival]).isEmpty)
    }

    func testFirstStationHasNoApproachingSegment() throws {
        let engine = try makeEngine()
        // Forward train "approaching" the first station has no previous
        // station behind it, so nothing can be derived.
        let arrival = Arrival(stationCode: 1, lineCode: "1", destination: "Nord", seconds: 30, rawText: "x")
        XCTAssertTrue(engine.positions(lineCode: "1", arrivals: [arrival]).isEmpty)
        // Backward train approaching the last station: same.
        let last = Arrival(stationCode: 3, lineCode: "1", destination: "Sud", seconds: 30, rawText: "x")
        XCTAssertTrue(engine.positions(lineCode: "1", arrivals: [last]).isEmpty)
    }

    func testEngineFailsWithTooFewStations() {
        let single = Array(stations.prefix(1))
        XCTAssertNil(TrainPositionEngine.make(stations: single, geometry: geometry))
        XCTAssertNil(TrainPositionEngine.make(stations: stations, geometry: LineGeometry(points: [])))
    }

    func testPositionsAreDeterministic() throws {
        let engine = try makeEngine()
        let arrivals = [
            Arrival(stationCode: 2, lineCode: "1", destination: "Nord", seconds: 60, rawText: "1 min"),
            Arrival(stationCode: 3, lineCode: "1", destination: "Sud", seconds: 120, rawText: "2 min"),
        ]
        XCTAssertEqual(engine.positions(lineCode: "1", arrivals: arrivals), engine.positions(lineCode: "1", arrivals: arrivals))
    }

    /// S1: the same train shows up at every station it will reach. Only the
    /// next one may be drawn, and the countdown stays out of the identity.
    func testArrivalsOfTheSameTrainCollapseToOnePosition() throws {
        let engine = try makeEngine()
        let arrivals = [
            arrival(stationCode: 3, seconds: 120),
            arrival(stationCode: 2, seconds: 30),
        ]
        let positions = engine.positions(lineCode: "1", arrivals: arrivals)

        XCTAssertEqual(positions.count, 1)
        let position = try XCTUnwrap(positions.first)
        XCTAssertEqual(position.id, "1-7-0011")
        XCTAssertEqual(position.nextStationCode, 2)
        XCTAssertEqual(position.secondsToArrival, 30)
    }

    func testTrainIdentityIgnoresTheCountdown() throws {
        let engine = try makeEngine()
        let first = engine.positions(lineCode: "1", arrivals: [arrival(seconds: 30)])
        let second = engine.positions(lineCode: "1", arrivals: [arrival(seconds: 45)])

        XCTAssertEqual(first.map(\.id), ["1-7-0011"])
        XCTAssertEqual(second.map(\.id), ["1-7-0011"])
    }

    /// Without a service code an arrival cannot be attributed to a train.
    func testArrivalsWithoutServiceCodeAreNeverCollapsed() throws {
        let engine = try makeEngine()
        let arrivals = [
            arrival(stationCode: 2, seconds: 30, serviceCode: nil, trajectCode: nil, via: nil),
            arrival(stationCode: 3, seconds: 120, serviceCode: nil, trajectCode: nil, via: nil),
        ]
        let positions = engine.positions(lineCode: "1", arrivals: arrivals)

        XCTAssertEqual(positions.count, 2)
        XCTAssertEqual(Set(positions.map(\.id)).count, 2)
    }

    /// S2: `codi_via` wins over the destination name.
    func testViaOverridesTheDestinationName() throws {
        let engine = try makeEngine()
        // "Sud" is the first station, but via 1 says the train travels toward
        // the last one.
        let forward = arrival(destination: "Sud", seconds: 60, serviceCode: "1", trajectCode: "0011", via: 1)
        let forwardPosition = try XCTUnwrap(engine.positions(lineCode: "1", arrivals: [forward]).first)
        XCTAssertTrue(forwardPosition.forward)

        // "Nord" is the last station, but via 2 says the opposite.
        let backward = arrival(destination: "Nord", seconds: 60, serviceCode: "2", trajectCode: "0012", via: 2)
        let backwardPosition = try XCTUnwrap(engine.positions(lineCode: "1", arrivals: [backward]).first)
        XCTAssertFalse(backwardPosition.forward)
    }

    func testDwellingThresholdIsFifteenSeconds() throws {
        let engine = try makeEngine()
        let dwelling = try XCTUnwrap(engine.positions(lineCode: "1", arrivals: [arrival(seconds: 15)]).first)
        XCTAssertTrue(dwelling.isDwelling)

        let moving = try XCTUnwrap(engine.positions(lineCode: "1", arrivals: [arrival(seconds: 16)]).first)
        XCTAssertFalse(moving.isDwelling)
    }
}

/// Unit tests for `GeoMath.nearestProjection`, the segment projection the
/// engine uses to place stations along the route.
final class GeoMathProjectionTests: XCTestCase {
    // One ~1.1 km north-south segment at constant longitude.
    private let start = GeoPoint(latitude: 41.3400, longitude: 2.1000)
    private let end = GeoPoint(latitude: 41.3500, longitude: 2.1000)

    func testPerpendicularFootAndEndClamping() throws {
        let points = [start, end]
        let cumulative = GeoMath.cumulativeDistances(of: points)
        let length = try XCTUnwrap(cumulative.last)

        // ~83 m east of the segment midpoint: the foot is straight west of the
        // point, half the segment from either end.
        let beside = GeoPoint(latitude: 41.3450, longitude: 2.1010)
        let projection = try XCTUnwrap(GeoMath.nearestProjection(of: beside, in: points, cumulative: cumulative))
        XCTAssertEqual(projection.segmentIndex, 0)
        XCTAssertEqual(projection.fraction, 0.5, accuracy: 0.001)
        XCTAssertEqual(projection.distance, length / 2, accuracy: 1.0)
        XCTAssertEqual(projection.offsetMeters, 83.5, accuracy: 1.0)

        // Past the north end: clamps to that end instead of overshooting.
        let beyond = GeoPoint(latitude: 41.3550, longitude: 2.1000)
        let clamped = try XCTUnwrap(GeoMath.nearestProjection(of: beyond, in: points, cumulative: cumulative))
        XCTAssertEqual(clamped.fraction, 1.0, accuracy: 1e-9)
        XCTAssertEqual(clamped.distance, length, accuracy: 1e-6)
        XCTAssertEqual(clamped.offsetMeters, GeoMath.distanceMeters(from: beyond, to: end), accuracy: 1e-6)
    }
}
