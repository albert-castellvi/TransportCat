import MapKit
import XCTest
@testable import TransportCat

/// S5: the map camera fits the stations of the selected line, instead of
/// staying on the fixed Barcelona region and cutting long lines such as L5 off.
final class MapRegionTests: XCTestCase {
    private func station(code: Int, latitude: Double, longitude: Double) -> Station {
        Station(code: code, name: "S\(code)", orderInLine: code, lineCode: "5",
                latitude: latitude, longitude: longitude, id: code, accessible: true)
    }

    func testEmptyStationListHasNoRegion() {
        XCTAssertNil(MapScreen.region(fitting: []))
    }

    func testRegionCentresTwoStationsAndPadsSpanByThirtyPercent() throws {
        let region = try XCTUnwrap(
            MapScreen.region(fitting: [
                station(code: 1, latitude: 41.30, longitude: 2.10),
                station(code: 2, latitude: 41.40, longitude: 2.20),
            ]),
            "two stations must produce a region"
        )
        XCTAssertEqual(region.center.latitude, 41.35, accuracy: 1e-9)
        XCTAssertEqual(region.center.longitude, 2.15, accuracy: 1e-9)
        // 0.1 degrees per axis, padded by 30 %.
        XCTAssertEqual(region.span.latitudeDelta, 0.13, accuracy: 1e-9)
        XCTAssertEqual(region.span.longitudeDelta, 0.13, accuracy: 1e-9)
    }

    func testSpanNeverFallsBelowMinimumOfOneHundredthDegree() throws {
        let stations = [
            station(code: 1, latitude: 41.37, longitude: 2.17),
            station(code: 2, latitude: 41.37, longitude: 2.17),
        ]
        let region = try XCTUnwrap(MapScreen.region(fitting: stations), "stations on one point must produce a region")
        XCTAssertEqual(region.span.latitudeDelta, 0.01, accuracy: 1e-9)
        XCTAssertEqual(region.span.longitudeDelta, 0.01, accuracy: 1e-9)
        XCTAssertEqual(region.center.latitude, 41.37, accuracy: 1e-9)
        XCTAssertEqual(region.center.longitude, 2.17, accuracy: 1e-9)
    }
}
