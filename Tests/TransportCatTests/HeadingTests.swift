import XCTest
@testable import TransportCat

/// Tests for the route bearing (spec S2): `GeoMath.bearingDegrees` and
/// `TrainPositionEngine.heading(atRouteDistance:forward:)`.
///
/// The bearings are degrees clockwise from north, so north is 0, east 90,
/// south 180 and west 270. A train travelling toward the first station reports
/// the reversed bearing, because heading is the travel direction.
final class HeadingTests: XCTestCase {
    // Same synthetic line as TrainPositionEngineTests: three stations ~504.6 m
    // apart on a straight north-south polyline, ordered south to north.
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

    private func makeEngine() throws -> TrainPositionEngine {
        try XCTUnwrap(TrainPositionEngine.make(stations: stations, geometry: geometry))
    }

    /// Shortest angular difference between two bearings, in degrees. Lets an
    /// assertion accept both 0 and 360 for the same direction.
    private func angularDistance(_ a: Double, _ b: Double) -> Double {
        let raw = abs(a - b).truncatingRemainder(dividingBy: 360)
        return min(raw, 360 - raw)
    }

    // MARK: - GeoMath.bearingDegrees

    func testCardinalBearings() {
        // Origin near Barcelona, ~1 km legs so the great-circle bearing is
        // unambiguous.
        let origin = GeoPoint(latitude: 41.3800, longitude: 2.1700)
        let metersPerDegree = GeoMath.earthRadiusMeters * .pi / 180
        let deltaLat = 1_000 / metersPerDegree
        let deltaLon = deltaLat / cos(origin.latitude * .pi / 180)

        let north = GeoPoint(latitude: origin.latitude + deltaLat, longitude: origin.longitude)
        let south = GeoPoint(latitude: origin.latitude - deltaLat, longitude: origin.longitude)
        let east = GeoPoint(latitude: origin.latitude, longitude: origin.longitude + deltaLon)
        let west = GeoPoint(latitude: origin.latitude, longitude: origin.longitude - deltaLon)

        XCTAssertEqual(GeoMath.bearingDegrees(from: origin, to: north), 0, accuracy: 0.5)
        XCTAssertEqual(GeoMath.bearingDegrees(from: origin, to: east), 90, accuracy: 0.5)
        XCTAssertEqual(GeoMath.bearingDegrees(from: origin, to: south), 180, accuracy: 0.5)
        XCTAssertEqual(GeoMath.bearingDegrees(from: origin, to: west), 270, accuracy: 0.5)
    }

    // MARK: - Engine heading

    /// A forward train on the north-south line faces north. The window spans a
    /// polyline vertex (the vertices are ~125 m apart), so this also proves
    /// the heading is not taken from a single segment.
    func testForwardTrainHeadingIsNorth() throws {
        let engine = try makeEngine()
        let heading = engine.heading(atRouteDistance: 504.6, forward: true)
        XCTAssertEqual(angularDistance(heading, 0), 0, accuracy: 1)
    }

    /// The same point travelled backwards faces south.
    func testBackwardTrainHeadingIsSouth() throws {
        let engine = try makeEngine()
        let heading = engine.heading(atRouteDistance: 504.6, forward: false)
        XCTAssertEqual(angularDistance(heading, 180), 0, accuracy: 1)
    }

    /// Every heading the engine can report is a normalized bearing, including
    /// at the clamped route ends where the window collapses.
    func testHeadingIsAlwaysNormalized() throws {
        let engine = try makeEngine()
        let total = try XCTUnwrap(GeoMath.cumulativeDistances(of: geometry.points).last)
        for distance in stride(from: -500.0, through: total + 500, by: 25) {
            for forward in [true, false] {
                let heading = engine.heading(atRouteDistance: distance, forward: forward)
                XCTAssertGreaterThanOrEqual(heading, 0, "distance \(distance), forward \(forward)")
                XCTAssertLessThan(heading, 360, "distance \(distance), forward \(forward)")
            }
        }
    }

    /// A window whose two ends coincide has no direction to measure and falls
    /// back to 0, instead of reporting an arbitrary bearing from a zero-length
    /// vector.
    func testZeroLengthWindowReturnsZero() throws {
        let origin = GeoPoint(latitude: 41.34467731, longitude: 2.10724192)
        // Degenerate route: every vertex is the same point, so both window
        // ends clamp onto it.
        let flatStations = [
            Station(code: 21, name: "A", orderInLine: 1, lineCode: "1", latitude: origin.latitude, longitude: origin.longitude, id: 95, accessible: true),
            Station(code: 22, name: "B", orderInLine: 2, lineCode: "1", latitude: origin.latitude, longitude: origin.longitude, id: 96, accessible: true),
        ]
        let flatGeometry = LineGeometry(points: [origin, origin])
        let flatEngine = try XCTUnwrap(TrainPositionEngine(stations: flatStations, geometry: flatGeometry))
        XCTAssertEqual(flatEngine.heading(atRouteDistance: 0, forward: true), 0)
        XCTAssertEqual(flatEngine.heading(atRouteDistance: 0, forward: false), 0)

        // On a real route the clamped ends still report the direction they
        // face, never a NaN.
        let engine = try makeEngine()
        XCTAssertEqual(angularDistance(engine.heading(atRouteDistance: 0, forward: true), 0), 0, accuracy: 1)
    }
}
