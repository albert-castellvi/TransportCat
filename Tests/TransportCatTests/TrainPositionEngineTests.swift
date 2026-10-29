import XCTest
@testable import TransportCat

final class TrainPositionEngineTests: XCTestCase {
    // Synthetic straight line: three stations, 500 m apart, along a
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

    private func makeEngine(speed: Double = 9.2) throws -> TrainPositionEngine {
        try XCTUnwrap(TrainPositionEngine.make(stations: stations, geometry: geometry, speedMetersPerSecond: speed))
    }

    func testSegmentLengthIsDistanceBetweenStations() throws {
        let engine = try makeEngine()
        // Halfway progress: an arrival at station 2 with exactly half the
        // segment duration remaining puts the train at the segment midpoint.
        let segmentMeters = GeoMath.distanceMeters(
            from: GeoPoint(latitude: 41.34467731, longitude: 2.10724192),
            to: GeoPoint(latitude: 41.34921585, longitude: 2.10724192)
        )
        let halfDuration = Int(segmentMeters / 9.2 / 2)
        let arrival = Arrival(stationCode: 2, lineCode: "1", destination: "Nord", seconds: halfDuration, rawText: "x")
        let positions = engine.positions(lineCode: "1", arrivals: [arrival])

        XCTAssertEqual(positions.count, 1)
        let position = try XCTUnwrap(positions.first)
        XCTAssertTrue(position.forward)
        XCTAssertEqual(position.segmentProgress, 0.5, accuracy: 0.01)
        // Midpoint latitude between station 1 and 2.
        XCTAssertEqual(position.position.latitude, 41.34694658, accuracy: 0.0005)
        // Longitude unchanged on this straight north-south line.
        XCTAssertEqual(position.position.longitude, 2.10724192, accuracy: 1e-6)
    }

    func testDirectionBackwardTowardFirstStation() throws {
        let engine = try makeEngine()
        let segmentMeters = GeoMath.distanceMeters(
            from: GeoPoint(latitude: 41.34921585, longitude: 2.10724192),
            to: GeoPoint(latitude: 41.35375440, longitude: 2.10724192)
        )
        let arrival = Arrival(stationCode: 2, lineCode: "1", destination: "Sud", seconds: Int(segmentMeters / 9.2 / 4))
        let positions = engine.positions(lineCode: "1", arrivals: [arrival])

        let position = try XCTUnwrap(positions.first)
        XCTAssertFalse(position.forward)
        // Approaching station 2 from the north: 3/4 of the way down.
        XCTAssertEqual(position.segmentProgress, 0.75, accuracy: 0.01)
        XCTAssertEqual(position.position.latitude, 41.3526725, accuracy: 0.0005)
    }

    func testOverdueArrivalClampsToPreviousStation() throws {
        let engine = try makeEngine()
        // 10_000 s remaining over a 500 m segment: raw progress far below 0.
        let arrival = Arrival(stationCode: 2, lineCode: "1", destination: "Nord", seconds: 10_000, rawText: "x")
        let positions = engine.positions(lineCode: "1", arrivals: [arrival])
        let position = try XCTUnwrap(positions.first)
        XCTAssertEqual(position.segmentProgress, 0.0, accuracy: 1e-9)
        XCTAssertEqual(position.position.latitude, 41.34467731, accuracy: 0.0005)
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
            Arrival(stationCode: 2, lineCode: "1", destination: "Nord", seconds: 60, rawText: "x"),
            Arrival(stationCode: 3, lineCode: "1", destination: "Sud", seconds: 120, rawText: "x"),
        ]
        XCTAssertEqual(engine.positions(lineCode: "1", arrivals: arrivals), engine.positions(lineCode: "1", arrivals: arrivals))
    }
}
