import XCTest

/// Tests for `NearbyStops` pure logic.
///
/// Runs on Linux via the harness (Foundation-only).
final class NearbyStopsTests: XCTestCase {

    // MARK: - walkingMinutes

    func testWalkingMinutes_zeroDistance() {
        XCTAssertEqual(NearbyStops.walkingMinutes(meters: 0), 0)
    }

    func testWalkingMinutes_smallDistance() {
        // 80 m → 1 min (floor of 1 for non-zero)
        XCTAssertEqual(NearbyStops.walkingMinutes(meters: 80), 1)
    }

    func testWalkingMinutes_exactMinutes() {
        // 80 m/min → 400 m = 5 min
        XCTAssertEqual(NearbyStops.walkingMinutes(meters: 400), 5)
    }

    func testWalkingMinutes_rounded() {
        // 120 m → 1.5 min → rounded to 2
        XCTAssertEqual(NearbyStops.walkingMinutes(meters: 120), 2)
    }

    // MARK: - sorted

    func testSorted_distanceThenName() {
        let entries = [
            NearbyStopEntry(place: Place(kind: .busStop, code: "1", name: "Zebra", position: GeoPoint(latitude: 0, longitude: 0), lineCodes: [], accessible: nil), distanceMeters: 500, walkingMinutes: 6, rows: []),
            NearbyStopEntry(place: Place(kind: .busStop, code: "2", name: "Alpha", position: GeoPoint(latitude: 0, longitude: 0), lineCodes: [], accessible: nil), distanceMeters: 300, walkingMinutes: 4, rows: []),
        ]
        let sorted = NearbyStops.sorted(entries)
        XCTAssertEqual(sorted[0].place.name, "Alpha")
        XCTAssertEqual(sorted[1].place.name, "Zebra")
    }

    func testSorted_capped() {
        let places = (1...15).map { i in
            NearbyStopEntry(
                place: Place(kind: .busStop, code: String(i), name: "Stop \(i)", position: GeoPoint(latitude: Double(i), longitude: 0), lineCodes: [], accessible: nil),
                distanceMeters: Double(i * 100),
                walkingMinutes: NearbyStops.walkingMinutes(meters: Double(i * 100)),
                rows: []
            )
        }
        let sorted = NearbyStops.sorted(places)
        XCTAssertEqual(sorted.count, 10)
    }

    // MARK: - timeText (metro)

    func testTimeText_imminent() {
        XCTAssertEqual(NearbyStops.timeText(seconds: 30), "ara")
    }

    func testTimeText_threshold() {
        XCTAssertEqual(NearbyStops.timeText(seconds: 60), "ara")
    }

    func testTimeText_aboveThreshold() {
        XCTAssertEqual(NearbyStops.timeText(seconds: 61), "1 min")
    }

    func testTimeText_none() {
        XCTAssertEqual(NearbyStops.timeText(seconds: nil), "—")
    }
}