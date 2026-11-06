import Foundation
import XCTest
@testable import TransportCat

/// Pure rules of the unified map incident badges and station icons (specs S6,
/// S7): the middle station of an affected run, where the single amber badge of
/// a run sits, and the metro–metro interchange lines of a station (D4).
final class MapIncidentBadgeTests: XCTestCase {
    // MARK: - Helpers

    private func station(
        _ code: Int,
        order: Int,
        name: String = "Estacio",
        lat: Double = 41.38,
        lon: Double = 2.17
    ) -> Station {
        Station(
            code: code,
            name: name,
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

    private func place(
        code: String,
        name: String,
        lines: [String],
        lat: Double = 41.38,
        lon: Double = 2.17
    ) -> Place {
        Place(
            kind: .metroStation,
            code: code,
            name: name,
            position: GeoPoint(latitude: lat, longitude: lon),
            lineCodes: lines,
            accessible: nil
        )
    }

    // MARK: - Middle station of a run

    func testEmptyRunHasNoMiddleStation() {
        let run = IncidentRun(stations: [])
        XCTAssertNil(IncidentBadgePlacement.middleStation(of: run))
    }

    func testSingleStationRunPlacesBadgeOnIt() {
        let only = station(10, order: 1)
        let run = IncidentRun(stations: [only])
        XCTAssertEqual(IncidentBadgePlacement.middleStation(of: run)?.code, 10)
    }

    func testTwoStationRunUsesTheLaterHalfPoint() {
        let first = station(10, order: 1)
        let second = station(20, order: 2)
        let run = IncidentRun(stations: [first, second])
        XCTAssertEqual(IncidentBadgePlacement.middleStation(of: run)?.code, 20)
    }

    func testThreeStationRunHasAnExactMiddle() {
        let run = IncidentRun(stations: [
            station(10, order: 1),
            station(20, order: 2),
            station(30, order: 3),
        ])
        XCTAssertEqual(IncidentBadgePlacement.middleStation(of: run)?.code, 20)
    }

    func testFourStationRunUsesTheSecondHalfPoint() {
        let run = IncidentRun(stations: [
            station(10, order: 1),
            station(20, order: 2),
            station(30, order: 3),
            station(40, order: 4),
        ])
        XCTAssertEqual(IncidentBadgePlacement.middleStation(of: run)?.code, 30)
    }

    // MARK: - Badge text for a run

    func testBadgeTextIsTheLineDisplayName() {
        XCTAssertEqual(IncidentBadgePlacement.badgeText(lineDisplayName: "L2"), "L2")
        XCTAssertEqual(IncidentBadgePlacement.badgeText(lineDisplayName: "H12"), "H12")
    }

    // MARK: - Badge for a whole run

    func testBadgeCarriesRunMiddleStationAndFirstAlert() {
        let run = IncidentRun(stations: [
            station(10, order: 1),
            station(20, order: 2),
            station(30, order: 3),
        ])
        let incidents: [Int: [StationIncident]] = [
            10: [incident(alertID: "A2", stationCode: 10)],
            20: [incident(alertID: "A1", stationCode: 20)],
            30: [incident(alertID: "A1", stationCode: 30)],
        ]
        let badge = IncidentBadgePlacement.badge(
            for: run,
            lineDisplayName: "L2",
            serviceIncidents: incidents
        )
        XCTAssertEqual(badge?.text, "L2")
        XCTAssertEqual(badge?.alertID, "A2")
        XCTAssertEqual(badge?.latitude, 41.38)
        XCTAssertEqual(badge?.runID, run.id)
    }

    func testRunWithoutServiceIncidentsProducesNoBadge() {
        let run = IncidentRun(stations: [station(10, order: 1)])
        XCTAssertNil(IncidentBadgePlacement.badge(
            for: run,
            lineDisplayName: "L2",
            serviceIncidents: [:]
        ))
    }

    // MARK: - Metro–metro interchange lines (D4)

    /// The catalog's merged place lists both lines; the line on screen never
    /// names itself.
    func testInterchangeReadsTheMergedPlaceLineCodes() {
        let stationLine1 = Station(
            code: 100,
            name: "Verneda",
            orderInLine: 3,
            lineCode: "1",
            latitude: 41.38,
            longitude: 2.17,
            id: 5000,
            accessible: nil
        )
        let places = [
            place(code: "5000", name: "Verneda", lines: ["L1", "L4"]),
        ]
        let result = StationInterchange.metroLineDisplayNames(
            for: stationLine1,
            places: places,
            lineCode: "1"
        )
        XCTAssertEqual(result, ["L4"])
    }

    /// A transfer whose halves are separate places shares the same physical
    /// name: the name match the feed itself uses joins them.
    func testInterchangeAlsoReadsSameNamePlaces() {
        let stationLine2 = station(200, order: 1, name: "Pl. Catalunya", lat: 41.38, lon: 2.17)
        let places = [
            place(code: "9001", name: "PL. CATALUNYA", lines: ["L3"], lat: 41.381, lon: 2.171),
        ]
        let result = StationInterchange.metroLineDisplayNames(
            for: stationLine2,
            places: places,
            lineCode: "2"
        )
        XCTAssertEqual(result, ["L3"])
    }

    /// Bus and FGC codes in the catalog are not metro lines, and unknown codes
    /// are dropped: D4 keeps the capsules metro–metro only.
    func testInterchangeIgnoresNonMetroLineCodes() {
        let stationOnLine1 = Station(
            code: 100,
            name: "Pl. Catalunya",
            orderInLine: 1,
            lineCode: "1",
            latitude: 41.38,
            longitude: 2.17,
            id: 5000,
            accessible: nil
        )
        let places = [
            place(code: "5000", name: "Pl. Catalunya", lines: ["L1", "S1", "H12"]),
        ]
        let result = StationInterchange.metroLineDisplayNames(
            for: stationOnLine1,
            places: places,
            lineCode: "1"
        )
        XCTAssertEqual(result, [])
    }

    func testInterchangeOutputFollowsMetroLineOrder() {
        let stationOnLine5 = Station(
            code: 100,
            name: "Diagonal",
            orderInLine: 6,
            lineCode: "5",
            latitude: 41.38,
            longitude: 2.17,
            id: 5000,
            accessible: nil
        )
        let places = [
            place(code: "5000", name: "Diagonal", lines: ["L3", "L5", "L4"]),
        ]
        let result = StationInterchange.metroLineDisplayNames(
            for: stationOnLine5,
            places: places,
            lineCode: "5"
        )
        // `MetroLine.allLines` order: L3 before L4.
        XCTAssertEqual(result, ["L3", "L4"])
    }

    /// Same name, but bus and FGC places: D4 is metro–metro only.
    func testInterchangeIgnoresBusAndFGCPlaces() {
        let places = [
            Place(
                kind: .busStop,
                code: "100",
                name: "La Pau",
                position: GeoPoint(latitude: 41.38, longitude: 2.17),
                lineCodes: ["L2"],
                accessible: nil
            ),
            Place(
                kind: .fgcStation,
                code: "PAU",
                name: "La Pau",
                position: GeoPoint(latitude: 41.38, longitude: 2.17),
                lineCodes: ["L4"],
                accessible: nil
            ),
        ]
        let result = StationInterchange.metroLineDisplayNames(
            for: station(10, order: 1, name: "La Pau"),
            places: places,
            lineCode: "1"
        )
        XCTAssertEqual(result, [])
    }

    func testStationWithoutAPlaceYieldsNoInterchange() {
        let result = StationInterchange.metroLineDisplayNames(
            for: station(10, order: 1, name: "Desconeguda"),
            places: [place(code: "5000", name: "Verneda", lines: ["L1"])],
            lineCode: "2"
        )
        XCTAssertEqual(result, [])
    }
}
