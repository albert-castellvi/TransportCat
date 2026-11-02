import XCTest
@testable import TransportCat

/// Pure grouping of affected metro stations into consecutive runs (spec S9).
final class IncidentSegmentsTests: XCTestCase {
    // MARK: - Helpers

    private func station(_ code: Int, order: Int, lat: Double = 41.38, lon: Double = 2.17) -> Station {
        Station(
            code: code,
            name: "E\(code)",
            orderInLine: order,
            lineCode: "1",
            latitude: lat,
            longitude: lon,
            id: nil,
            accessible: nil
        )
    }

    private func incident(alertID: String, stationCode: Int) -> StationIncident {
        StationIncident(
            id: "\(alertID)-\(stationCode)",
            alertID: alertID,
            kind: .other,
            title: "Incidència",
            text: nil,
            entrance: nil
        )
    }

    /// An `IncidentIndex`-shaped dictionary marking exactly these codes.
    private func affected(_ codes: [Int]) -> [Int: [StationIncident]] {
        Dictionary(uniqueKeysWithValues: codes.map { ($0, [incident(alertID: "A\($0)", stationCode: $0)]) })
    }

    /// Five stations in line order 1...5 with distinct codes 10...50.
    private var lineStations: [Station] {
        [
            station(10, order: 1),
            station(20, order: 2),
            station(30, order: 3),
            station(40, order: 4),
            station(50, order: 5),
        ]
    }

    // MARK: - runs (grouping)

    func testEmptyInputsProduceNoRuns() {
        XCTAssertEqual(IncidentSegments.runs(stations: [], incidents: [:]), [])
    }

    func testNoAffectedStationProducesNoRuns() {
        XCTAssertEqual(IncidentSegments.runs(stations: lineStations, incidents: [:]), [])
    }

    /// A station mapped to an empty incident list is clean, not affected.
    func testEmptyIncidentListDoesNotCountAsAffected() {
        let incidents = [20: [StationIncident]()]
        XCTAssertEqual(IncidentSegments.runs(stations: lineStations, incidents: incidents), [])
    }

    func testSingleAffectedStationIsARunOfOne() {
        let runs = IncidentSegments.runs(stations: lineStations, incidents: affected([30]))
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].stations.map(\.code), [30])
        XCTAssertEqual(runs[0].id, 3)
    }

    func testAdjacentAffectedStationsFormOneRun() {
        let runs = IncidentSegments.runs(stations: lineStations, incidents: affected([10, 20, 30]))
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].stations.map(\.code), [10, 20, 30])
        XCTAssertEqual(runs[0].firstStation?.code, 10)
        XCTAssertEqual(runs[0].lastStation?.code, 30)
    }

    func testCleanStationSplitsTwoRuns() {
        // Codes 10,20 affected, 30 clean, 40,50 affected: two runs of two.
        let runs = IncidentSegments.runs(stations: lineStations, incidents: affected([10, 20, 40, 50]))
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs[0].stations.map(\.code), [10, 20])
        XCTAssertEqual(runs[1].stations.map(\.code), [40, 50])
    }

    func testRunsAreOrderedByLinePosition() {
        // The single station at the end of the line comes after the run at
        // the beginning, whatever order the incidents dictionary has.
        let runs = IncidentSegments.runs(stations: lineStations, incidents: affected([50, 10, 20]))
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs[0].stations.map(\.code), [10, 20])
        XCTAssertEqual(runs[1].stations.map(\.code), [50])
    }

    /// Adjacency is line order, not array order: an unordered station array
    /// must group the same way as the ordered one.
    func testUnorderedInputGroupsInLineOrder() {
        let shuffled = [lineStations[2], lineStations[0], lineStations[4], lineStations[1], lineStations[3]]
        let runs = IncidentSegments.runs(stations: shuffled, incidents: affected([10, 20, 30]))
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].stations.map(\.code), [10, 20, 30])
    }

    func testEveryStationAffectedIsOneRun() {
        let runs = IncidentSegments.runs(
            stations: lineStations,
            incidents: affected([10, 20, 30, 40, 50])
        )
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].stations.map(\.code), [10, 20, 30, 40, 50])
        XCTAssertEqual(runs[0].id, 1)
    }

    func testAlternatingStationsProduceOneRunPerStation() {
        let runs = IncidentSegments.runs(stations: lineStations, incidents: affected([10, 30, 50]))
        XCTAssertEqual(runs.count, 3)
        XCTAssertEqual(runs.map { $0.stations.count }, [1, 1, 1])
        XCTAssertEqual(runs.map(\.id), [1, 3, 5])
    }

    // MARK: - trackPolyline (geometry slicing)

    /// A north-south polyline with a vertex every 0.01° of latitude at lon 0.
    private var straightGeometry: LineGeometry {
        LineGeometry(points: (0...4).map { step in
            GeoPoint(latitude: Double(step) * 0.01, longitude: 0)
        })
    }

    private func stationOnLine(_ code: Int, order: Int, lat: Double) -> Station {
        station(code, order: order, lat: lat, lon: 0)
    }

    func testTrackPolylineFollowsGeometryBetweenRunEnds() throws {
        let run = IncidentRun(stations: [
            stationOnLine(10, order: 1, lat: 0.01),
            stationOnLine(20, order: 2, lat: 0.02),
            stationOnLine(30, order: 3, lat: 0.03),
        ])
        let points = try XCTUnwrap(IncidentSegments.trackPolyline(for: run, geometry: straightGeometry))
        XCTAssertEqual(points.count, 3)
        XCTAssertEqual(points.first?.latitude ?? 0, 0.01, accuracy: 0.000001)
        XCTAssertEqual(points.last?.latitude ?? 0, 0.03, accuracy: 0.000001)
        XCTAssertEqual(points[1].latitude, 0.02, accuracy: 0.000001)
        for point in points {
            XCTAssertEqual(point.longitude, 0, accuracy: 0.000001)
        }
    }

    /// Stations between two vertices cut the segments: the overlay starts and
    /// ends on the projections, not on the station coordinates off the track.
    func testTrackPolylineCutsInsideSegments() throws {
        let run = IncidentRun(stations: [
            // 0.0004° east of the track: the projection foot is the vertex row.
            station(10, order: 1, lat: 0.015, lon: 0.0004),
            station(20, order: 2, lat: 0.025, lon: 0.0004),
        ])
        let points = try XCTUnwrap(IncidentSegments.trackPolyline(for: run, geometry: straightGeometry))
        XCTAssertEqual(points.count, 3)
        XCTAssertEqual(points.first?.latitude ?? 0, 0.015, accuracy: 0.00001)
        XCTAssertEqual(points.first?.longitude ?? 1, 0, accuracy: 0.00001)
        XCTAssertEqual(points.last?.latitude ?? 0, 0.025, accuracy: 0.00001)
        XCTAssertEqual(points[1].latitude, 0.02, accuracy: 0.000001)
    }

    func testTrackPolylineNeedsAtLeastTwoStations() {
        let run = IncidentRun(stations: [stationOnLine(10, order: 1, lat: 0.01)])
        XCTAssertNil(IncidentSegments.trackPolyline(for: run, geometry: straightGeometry))
    }

    func testTrackPolylineNilWithoutGeometryPoints() {
        let run = IncidentRun(stations: [
            stationOnLine(10, order: 1, lat: 0.01),
            stationOnLine(20, order: 2, lat: 0.03),
        ])
        XCTAssertNil(IncidentSegments.trackPolyline(for: run, geometry: LineGeometry(points: [])))
    }

    /// On a route that doubles back, the last station can project BEFORE the
    /// first one along the polyline: there is no usable slice and the caller
    /// must fall back to the straight station-to-station line.
    func testTrackPolylineNilWhenProjectionsAreInverted() {
        let folded = LineGeometry(points: [
            GeoPoint(latitude: 0, longitude: 0),
            GeoPoint(latitude: 0.04, longitude: 0),
            GeoPoint(latitude: 0.04, longitude: 0.02),
            GeoPoint(latitude: 0, longitude: 0.02),
        ])
        let run = IncidentRun(stations: [
            station(10, order: 1, lat: 0.0405, lon: 0.0001),  // near the far end of leg 1
            station(20, order: 2, lat: 0.0005, lon: 0.0001),  // near the start of leg 1
        ])
        XCTAssertNil(IncidentSegments.trackPolyline(for: run, geometry: folded))
    }

    // MARK: - stationPolyline (fallback)

    func testStationPolylineJoinsTheStationsInOrder() throws {
        let run = IncidentRun(stations: [
            station(10, order: 1, lat: 41.40, lon: 2.10),
            station(20, order: 2, lat: 41.41, lon: 2.11),
            station(30, order: 3, lat: 41.42, lon: 2.12),
        ])
        let points = try XCTUnwrap(IncidentSegments.stationPolyline(for: run))
        XCTAssertEqual(points, [
            GeoPoint(latitude: 41.40, longitude: 2.10),
            GeoPoint(latitude: 41.41, longitude: 2.11),
            GeoPoint(latitude: 41.42, longitude: 2.12),
        ])
    }

    func testStationPolylineNilForSingleStationRun() {
        let run = IncidentRun(stations: [station(10, order: 1)])
        XCTAssertNil(IncidentSegments.stationPolyline(for: run))
    }

    // MARK: - End to end with the real IncidentIndex (S9)

    /// The exact pipeline the map runs: feed alerts → `IncidentIndex` → runs.
    /// 10 and 20 share one alert and sit adjacent; 50 has its own alert and is
    /// separated from them by two clean stations.
    func testRunsFollowTheRealIncidentIndex() {
        let alerts = [
            ServiceAlert(
                id: "9001",
                lineCodes: ["1"],
                stationNames: [],
                beginDate: nil,
                endDate: nil,
                text: nil,
                stationCodes: [10, 20]
            ),
            ServiceAlert(
                id: "9002",
                lineCodes: ["1"],
                stationNames: [],
                beginDate: nil,
                endDate: nil,
                text: nil,
                stationCodes: [50],
                effectCode: "PP9"
            ),
        ]
        let incidents = IncidentIndex.incidents(for: alerts, stations: lineStations, lineCode: "1")
        let runs = IncidentSegments.runs(stations: lineStations, incidents: incidents)
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs[0].stations.map(\.code), [10, 20])
        XCTAssertEqual(runs[1].stations.map(\.code), [50])
    }
}
