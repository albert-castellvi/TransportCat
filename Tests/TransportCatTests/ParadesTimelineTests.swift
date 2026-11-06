import XCTest
@testable import TransportCat

/// Pure row-model rules of the Parades screens (spec S8, T2). Foundation-only
/// inputs: the `Station`, `Arrival` and `StationIncident` shapes the real
/// state types publish, so no poller or network is involved.
final class ParadesTimelineTests: XCTestCase {
    // MARK: - Helpers

    private func station(
        _ code: Int,
        name: String = "Estació",
        order: Int,
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

    private func arrival(
        stationCode: Int = 10,
        seconds: Int?,
        via: Int?,
        destination: String = "Fondo"
    ) -> Arrival {
        Arrival(
            stationCode: stationCode,
            lineCode: "1",
            destination: destination,
            seconds: seconds,
            rawText: seconds.map { Arrival.countdownText(seconds: $0) } ?? "",
            via: via
        )
    }

    private func incident(
        alertID: String,
        stationCode: Int,
        kind: IncidentKind = .other
    ) -> StationIncident {
        StationIncident(
            id: "\(alertID)-\(stationCode)",
            alertID: alertID,
            kind: kind,
            title: "Incidència",
            text: nil,
            entrance: nil
        )
    }

    // MARK: - metroColumn ("ara" / "<n> min" / "—")

    func testColumnWithoutArrivalsShowsDash() {
        XCTAssertEqual(
            ParadesTimeline.metroColumn(arrivals: [], via: 1),
            .none
        )
    }

    func testColumnIgnoresArrivalsOfOtherDirection() {
        let arrivals = [arrival(seconds: 120, via: 2)]
        XCTAssertEqual(
            ParadesTimeline.metroColumn(arrivals: arrivals, via: 1),
            .none
        )
    }

    func testColumnIgnoresArrivalsWithoutCountdown() {
        let arrivals = [arrival(seconds: nil, via: 1)]
        XCTAssertEqual(
            ParadesTimeline.metroColumn(arrivals: arrivals, via: 1),
            .none
        )
    }

    func testImminentArrivalReadsNow() {
        XCTAssertEqual(
            ParadesTimeline.metroColumn(arrivals: [arrival(seconds: 30, via: 1)], via: 1),
            .now
        )
    }

    func testArrivalAtExactlyTheThresholdReadsNow() {
        XCTAssertEqual(
            ParadesTimeline.metroColumn(arrivals: [arrival(seconds: 60, via: 1)], via: 1),
            .now
        )
    }

    func testLaterArrivalReadsCountdownText() {
        let text = ParadesTimeline.metroColumn(arrivals: [arrival(seconds: 120, via: 1)], via: 1)
        XCTAssertEqual(text, .minutes("2 min"))
        XCTAssertEqual(text.text, "2 min")
        XCTAssertFalse(text.isImminent)
    }

    func testColumnPicksTheSoonestArrivalOfTheDirection() {
        let arrivals = [
            arrival(seconds: 300, via: 1),
            arrival(seconds: 180, via: 1),
            arrival(seconds: 30, via: 2),
        ]
        XCTAssertEqual(
            ParadesTimeline.metroColumn(arrivals: arrivals, via: 1),
            .minutes("3 min")
        )
    }

    func testNowIsTheOnlyImminentText() {
        XCTAssertTrue(ParadesTimeText.now.isImminent)
        XCTAssertFalse(ParadesTimeText.none.isImminent)
        XCTAssertFalse(ParadesTimeText.minutes("2 min").isImminent)
    }

    // MARK: - metroTerminiNames (sticky header)

    func testTerminiNameBothEndsInOrder() {
        let stations = [
            station(30, name: "Terci", order: 3),
            station(10, name: "Primer", order: 1),
            station(20, name: "Segon", order: 2),
        ]
        let termini = ParadesTimeline.metroTerminiNames(in: stations)
        XCTAssertEqual(termini?.first, "Primer")
        XCTAssertEqual(termini?.last, "Terci")
    }

    func testTerminiOfSingleStationLineIsNil() {
        XCTAssertNil(ParadesTimeline.metroTerminiNames(in: [station(10, name: "Única", order: 1)]))
        XCTAssertNil(ParadesTimeline.metroTerminiNames(in: []))
    }

    // MARK: - nearestStation ("Ets aquí")

    func testNearestStationPicksSmallestDistance() {
        let stations = [
            station(10, order: 1, lat: 41.380, lon: 2.170),
            station(20, order: 2, lat: 41.390, lon: 2.170),
        ]
        let user = GeoPoint(latitude: 41.3899, longitude: 2.170)
        let pick = ParadesTimeline.nearestStation(stations: stations, userLocation: user)
        XCTAssertEqual(pick?.station.code, 20)
    }

    func testNearestStationWithoutFixIsNil() {
        let stations = [station(10, order: 1)]
        XCTAssertNil(ParadesTimeline.nearestStation(stations: stations, userLocation: nil))
        XCTAssertNil(ParadesTimeline.nearestStation(stations: [], userLocation: GeoPoint(latitude: 41.38, longitude: 2.17)))
    }

    /// Two stations at exactly the same distance: the lower code wins, so the
    /// pick is deterministic across re-renders.
    func testNearestStationTieBreaksOnLowerCode() {
        // Two points equidistant north and south of the user.
        let stations = [
            station(20, order: 2, lat: 41.381, lon: 2.170),
            station(10, order: 1, lat: 41.379, lon: 2.170),
        ]
        let user = GeoPoint(latitude: 41.380, longitude: 2.170)
        let pick = ParadesTimeline.nearestStation(stations: stations, userLocation: user)
        XCTAssertEqual(pick?.station.code, 10)
    }

    func testHereTextFormatsMetersAndKilometers() {
        XCTAssertEqual(ParadesTimeline.hereText(distanceMeters: 250), "Ets aquí · 250 m")
        XCTAssertEqual(ParadesTimeline.hereText(distanceMeters: 0), "Ets aquí · 0 m")
        XCTAssertEqual(ParadesTimeline.hereText(distanceMeters: 1_250), "Ets aquí · 1,3 km")
    }

    // MARK: - metroInterchangeCodes (D4: metro-metro only)

    private func withLineCode(_ station: Station, _ lineCode: String) -> Station {
        Station(
            code: station.code,
            name: station.name,
            orderInLine: station.orderInLine,
            lineCode: lineCode,
            latitude: station.latitude,
            longitude: station.longitude,
            id: nil,
            accessible: nil
        )
    }

    func testInterchangeListsOtherLinesSharingTheName() {
        let all = [
            withLineCode(station(10, name: "La Pau", order: 1, lat: 41.4, lon: 2.1), "1"),
            withLineCode(station(20, name: "La Pau", order: 5, lat: 41.4, lon: 2.1), "2"),
            withLineCode(station(30, name: "La Pau", order: 3, lat: 41.4, lon: 2.1), "4"),
        ]
        let badges = ParadesTimeline.metroInterchangeCodes(for: all[0], lineCode: "1", allStations: all)
        // All-lines order: L2 (code "2") before L4 (code "4").
        XCTAssertEqual(badges, ["L2", "L4"])
    }

    func testInterchangeIgnoresDifferentNames() {
        let all = [
            station(10, name: "La Pau", order: 1, lat: 41.4, lon: 2.1),
            station(20, name: "Vermeda", order: 5, lat: 41.4, lon: 2.1),
        ]
        XCTAssertTrue(ParadesTimeline.metroInterchangeCodes(for: all[0], lineCode: "1", allStations: all).isEmpty)
    }

    func testInterchangeMatchIsCaseAndAccentInsensitive() {
        let all = [
            withLineCode(station(10, name: "Pl. Catalunya", order: 1, lat: 41.4, lon: 2.1), "1"),
            withLineCode(station(20, name: "PL. CATALUNYA", order: 5, lat: 41.4, lon: 2.1), "3"),
        ]
        XCTAssertEqual(
            ParadesTimeline.metroInterchangeCodes(for: all[0], lineCode: "1", allStations: all),
            ["L3"]
        )
    }

    func testInterchangeNeverListsItsOwnLine() {
        let all = [
            station(10, name: "La Pau", order: 1, lat: 41.4, lon: 2.1),
            withLineCode(station(20, name: "La Pau", order: 5, lat: 41.4, lon: 2.1), "1"),
        ]
        // The candidate shares the name but its line is the row's own line.
        XCTAssertTrue(ParadesTimeline.metroInterchangeCodes(for: all[0], lineCode: "1", allStations: all).isEmpty)
    }

    func testInterchangeIgnoresUnknownLineCodes() {
        // A station whose line code is not a MetroLine (a feed glitch) is
        // skipped, never shown as an unknown badge.
        let all = [
            station(10, name: "La Pau", order: 1, lat: 41.4, lon: 2.1),
            withLineCode(station(20, name: "La Pau", order: 5, lat: 41.4, lon: 2.1), "999"),
        ]
        XCTAssertTrue(ParadesTimeline.metroInterchangeCodes(for: all[0], lineCode: "1", allStations: all).isEmpty)
    }

    // MARK: - facility vs service incidents

    func testFacilityKindsAreTheAccessibilityOnes() {
        XCTAssertTrue(ParadesTimeline.isFacilityIncident(incident(alertID: "A", stationCode: 1, kind: .escalator)))
        XCTAssertTrue(ParadesTimeline.isFacilityIncident(incident(alertID: "A", stationCode: 1, kind: .elevator)))
        XCTAssertTrue(ParadesTimeline.isFacilityIncident(incident(alertID: "A", stationCode: 1, kind: .accessClosed)))
        XCTAssertFalse(ParadesTimeline.isFacilityIncident(incident(alertID: "A", stationCode: 1, kind: .stopClosed)))
        XCTAssertFalse(ParadesTimeline.isFacilityIncident(incident(alertID: "A", stationCode: 1, kind: .detour)))
        XCTAssertFalse(ParadesTimeline.isFacilityIncident(incident(alertID: "A", stationCode: 1, kind: .other)))
    }

    // MARK: - service cards (one per affected run)

    func testServiceCardsAreEmptyWhenNothingIsAffected() {
        XCTAssertEqual(ParadesTimeline.serviceCardAlertIDs(stations: [], incidents: [:]), [])
    }

    func testOneCardPerConsecutiveRun() {
        let stations = [
            station(10, order: 1),
            station(20, order: 2),
            station(30, order: 3),
            station(40, order: 4),
        ]
        let incidents: [Int: [StationIncident]] = [
            10: [incident(alertID: "A", stationCode: 10)],
            20: [incident(alertID: "A", stationCode: 20)],
            30: [incident(alertID: "B", stationCode: 30)],
        ]
        XCTAssertEqual(ParadesTimeline.serviceCardAlertIDs(stations: stations, incidents: incidents), ["A", "B"])
    }

    func testServiceCardsFollowStationOrderNotDictionaryOrder() {
        let stations = [
            station(40, order: 4),
            station(10, order: 1),
        ]
        let incidents: [Int: [StationIncident]] = [
            40: [incident(alertID: "Late", stationCode: 40)],
            10: [incident(alertID: "Early", stationCode: 10)],
        ]
        XCTAssertEqual(
            ParadesTimeline.serviceCardAlertIDs(stations: stations, incidents: incidents),
            ["Early", "Late"]
        )
    }

    // MARK: - dotted edges (affected runs on the rail)

    func testEdgeIsAffectedWhenEitherEndStationIsAffected() {
        XCTAssertTrue(ParadesTimeline.isEdgeAffected(fromStationCode: 10, nextStationCode: 20, affectedCodes: [20]))
        XCTAssertTrue(ParadesTimeline.isEdgeAffected(fromStationCode: 10, nextStationCode: 20, affectedCodes: [10]))
        XCTAssertFalse(ParadesTimeline.isEdgeAffected(fromStationCode: 10, nextStationCode: 20, affectedCodes: [30]))
    }

    func testLastStationHasNoEdge() {
        XCTAssertFalse(ParadesTimeline.isEdgeAffected(fromStationCode: 10, nextStationCode: nil, affectedCodes: [10]))
    }

    // MARK: - bus next two (spec S9)

    private func busArrival(
        stopCode: Int = 100,
        seconds: Int,
        directionID: Int,
        busID: Int? = 1
    ) -> BusArrival {
        BusArrival(
            stopCode: stopCode,
            lineCode: 212,
            lineName: "H12",
            directionID: directionID,
            trajectCode: "T1",
            destination: "Av. Esplugues",
            seconds: seconds,
            busID: busID,
            rampStatus: nil
        )
    }

    func testNextTwoBusesAreTheTwoSoonestOfTheDirection() {
        let arrivals = [
            busArrival(seconds: 500, directionID: 1),
            busArrival(seconds: 120, directionID: 1),
            busArrival(seconds: 60, directionID: 2),
            busArrival(seconds: 300, directionID: 1),
        ]
        let pick = ParadesTimeline.busNextTwo(arrivals: arrivals, directionID: 1)
        XCTAssertEqual(pick.next?.seconds, 120)
        XCTAssertEqual(pick.after?.seconds, 300)
    }

    func testNextTwoBusesWithOneArrival() {
        let pick = ParadesTimeline.busNextTwo(arrivals: [busArrival(seconds: 90, directionID: 2)], directionID: 2)
        XCTAssertEqual(pick.next?.seconds, 90)
        XCTAssertNil(pick.after)
    }

    func testNextTwoBusesWithNoArrivals() {
        let pick = ParadesTimeline.busNextTwo(arrivals: [], directionID: 1)
        XCTAssertNil(pick.next)
        XCTAssertNil(pick.after)
    }

    func testBusTimeTextImminentAndCountdown() {
        XCTAssertEqual(ParadesTimeline.busTimeText(seconds: 45), "ara")
        XCTAssertEqual(ParadesTimeline.busTimeText(seconds: 150), "2 min")
    }
}
