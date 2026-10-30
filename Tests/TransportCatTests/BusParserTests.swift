import XCTest
@testable import TransportCat

final class BusParserTests: XCTestCase {
    // MARK: - Helpers

    private func lines() throws -> [BusLine] {
        try BusParser.lines(from: Fixtures.data("bus-lines-sample"))
    }

    private func stops() throws -> [BusStop] {
        try BusParser.stops(from: Fixtures.data("bus-stops-212"))
    }

    private func routes() throws -> [BusRoute] {
        try BusParser.routes(from: Fixtures.data("bus-recs-212"))
    }

    /// Wraps one entry of the captured iBus snapshot into the payload shape the
    /// endpoint returns for a single stop, so the parser is tested against the
    /// real field names and values.
    private func ibusPayload(fromSnapshotStop code: String) throws -> Data {
        let root = try JSONSerialization.jsonObject(with: Fixtures.data("ibus-H12-snapshot"))
        let stops = try XCTUnwrap(JSONValue.dictionary(from: root)?["stops"] as? [String: Any])
        let entry = try XCTUnwrap(JSONValue.dictionary(from: stops[code]))
        let payload: [String: Any] = [
            "timestamp": try XCTUnwrap(entry["timestamp"]),
            "parades": [[
                "codi_parada": try XCTUnwrap(Int(code)),
                "linies_trajectes": try XCTUnwrap(entry["linies_trajectes"]),
            ]],
        ]
        return try JSONSerialization.data(withJSONObject: payload)
    }

    // MARK: - Lines (S2)

    func testLinesParseTheWholeCatalogEntry() throws {
        let lines = try lines()
        XCTAssertEqual(lines.count, 13)

        let h12 = try XCTUnwrap(lines.first { $0.name == "H12" })
        XCTAssertEqual(h12.code, 212)
        XCTAssertEqual(h12.id, 212)
        XCTAssertEqual(h12.description, "Gornal / Besòs Verneda")
        XCTAssertEqual(h12.origin, "Gornal")
        XCTAssertEqual(h12.destination, "Besòs Verneda")
        XCTAssertEqual(h12.colorHex, "003888")
        XCTAssertEqual(h12.textColorHex, "FFFFFF")
        // The catalog groups by CODI_FAMILIA and orders by ORDRE_FAMILIA.
        XCTAssertEqual(h12.familyCode, 6)
        XCTAssertEqual(h12.familyName, "Horitzontals")
        XCTAssertEqual(h12.familyOrder, 11)
        XCTAssertEqual(h12.order, 212)
    }

    func testLinesAreSortedByFamilyOrderThenLineOrder() throws {
        let lines = try lines()
        for (previous, next) in zip(lines, lines.dropFirst()) {
            let ordered = previous.familyOrder < next.familyOrder
                || (previous.familyOrder == next.familyOrder && previous.order <= next.order)
            XCTAssertTrue(
                ordered,
                "\(previous.name) (\(previous.familyOrder)/\(previous.order)) must not precede \(next.name) (\(next.familyOrder)/\(next.order))"
            )
        }
        // Diagonals is the first family in the sample and Llançadores the last.
        XCTAssertEqual(lines.first?.name, "D20")
        XCTAssertEqual(lines.last?.name, "984")
    }

    // MARK: - Stops (S3)

    func testStopsKeepAPIOrderAndCarryTheirDirection() throws {
        let stops = try stops()
        XCTAssertEqual(stops.count, 68)
        // Both directions come in a single list, 34 stops each.
        XCTAssertEqual(stops.filter { $0.directionID == 1 }.count, 34)
        XCTAssertEqual(stops.filter { $0.directionID == 2 }.count, 34)
        // The API order is kept: the first feature is a Tornada stop with order 17.
        XCTAssertEqual(stops.first?.code, 7)
        XCTAssertEqual(stops.first?.directionID, 2)
        XCTAssertEqual(stops.first?.order, 17)

        for directionID in [1, 2] {
            let orders = stops.filter { $0.directionID == directionID }.map(\.order).sorted()
            XCTAssertEqual(orders, Array(1...34), "direction \(directionID) must have orders 1...34")
        }
    }

    func testStopFieldsDecodeFromTheRealFeatures() throws {
        let stops = try stops()
        let stop = try XCTUnwrap(stops.first { $0.code == 7 && $0.directionID == 2 })
        XCTAssertEqual(stop.name, "Pl Universitat")
        XCTAssertEqual(stop.address, "Gran Via Corts Catalanes, 585")
        XCTAssertEqual(stop.order, 17)
        XCTAssertEqual(stop.directionName, "Tornada")
        XCTAssertEqual(stop.destinationName, "Gornal")
        XCTAssertEqual(stop.distanceFromPrevious, 362.78175, accuracy: 0.00001)
        XCTAssertEqual(stop.routeID, 5143824)
        XCTAssertEqual(stop.latitude, 41.38590663, accuracy: 0.00000001)
        XCTAssertEqual(stop.longitude, 2.16330982, accuracy: 0.00000001)
        // The same physical stop appears in both directions, so identity needs
        // the direction as well as the code.
        XCTAssertEqual(stop.id, "2-7")

        // The first stop of each direction is the route's origin: no distance
        // from a previous stop.
        let anada = stops.filter { $0.directionID == 1 }
        let firstAnada = try XCTUnwrap(anada.min { $0.order < $1.order })
        XCTAssertEqual(firstAnada.code, 3225)
        XCTAssertEqual(firstAnada.name, "Gornal - Final de trajecte")
        XCTAssertEqual(firstAnada.distanceFromPrevious, 0)
        XCTAssertEqual(firstAnada.destinationName, "Besòs Verneda")
        XCTAssertEqual(firstAnada.routeID, 4893833)
    }

    func testStopProjectsIntoTheMetroStationShape() throws {
        let stops = try stops()
        let stop = try XCTUnwrap(stops.first { $0.code == 7 && $0.directionID == 2 })
        let station = stop.asStation(lineCode: "212")
        XCTAssertEqual(station.code, 7)
        XCTAssertEqual(station.name, "Pl Universitat")
        XCTAssertEqual(station.orderInLine, 17)
        XCTAssertEqual(station.lineCode, "212")
        XCTAssertEqual(station.latitude, 41.38590663, accuracy: 0.00000001)
        XCTAssertEqual(station.longitude, 2.16330982, accuracy: 0.00000001)
        XCTAssertNil(station.id)
        XCTAssertNil(station.accessible)
    }

    // MARK: - Routes (S3)

    func testRoutesDecodeEveryVariantWithGeometry() throws {
        let routes = try routes()
        XCTAssertEqual(routes.count, 4)
        XCTAssertEqual(Set(routes.map(\.routeID)), [5103142, 4970937, 5143824, 4893833])
        for route in routes {
            XCTAssertFalse(route.geometry.points.isEmpty, "route \(route.routeID) has no polyline")
        }
        // A direction draws the variant whose route id its stops carry.
        let byID = Dictionary(uniqueKeysWithValues: routes.map { ($0.routeID, $0) })
        XCTAssertEqual(byID[4893833]?.directionID, 1)
        XCTAssertEqual(byID[4893833]?.geometry.points.count, 199)
        XCTAssertEqual(byID[5143824]?.directionID, 2)
        XCTAssertEqual(byID[5143824]?.geometry.points.count, 163)

        for directionID in [1, 2] {
            let stops = try stops().filter { $0.directionID == directionID }
            let stopRouteIDs = Set(stops.map(\.routeID))
            XCTAssertTrue(
                stopRouteIDs.allSatisfy { byID[$0] != nil },
                "direction \(directionID) points at a route the /recs response does not have"
            )
        }
    }

    // MARK: - Arrivals (S4, S6)

    func testArrivalsFromARealSnapshotStop() throws {
        let data = try ibusPayload(fromSnapshotStop: "7")
        let arrivals = try BusParser.arrivals(from: data, stopCode: 7)

        XCTAssertEqual(arrivals.count, 2)
        let first = try XCTUnwrap(arrivals.first)
        XCTAssertEqual(first.stopCode, 7)
        XCTAssertEqual(first.lineCode, 212)
        XCTAssertEqual(first.lineName, "H12")
        XCTAssertEqual(first.directionID, 2)
        XCTAssertEqual(first.trajectCode, "2121")
        XCTAssertEqual(first.destination, "Gornal")
        XCTAssertEqual(first.busID, 8560)
        XCTAssertEqual(first.rampStatus, "SENSE_INCIDENCIA")
        XCTAssertEqual(first.rampOperational, true)
        // The countdown is the arrival minus the response timestamp.
        XCTAssertEqual(first.seconds, 200)
        XCTAssertEqual(first.id, "7-212-8560")

        XCTAssertEqual(arrivals.map(\.seconds), [200, 587])
        XCTAssertEqual(arrivals.map(\.busID), [8560, 6122])
    }

    func testArrivalsKeepEveryLineAndClampOverdueBuses() throws {
        let json = """
        {"timestamp": 1700000000000, "parades": [{"codi_parada": 1234, "linies_trajectes": [
          {"codi_linia": 212, "nom_linia": "H12", "id_sentit": 1, "codi_trajecte": "2122",
           "desti_trajecte": "Besòs Verneda", "propers_busos": [
            {"temps_arribada": 1700000060000, "id_bus": null, "info_bus": {"accessibilitat": {"estat_rampa": "RATLLADA"}}},
            {"temps_arribada": 1699999940000, "id_bus": 77},
            {"temps_arribada": 1700001200000, "id_bus": 78, "info_bus": {"accessibilitat": {"estat_rampa": "SENSE_INCIDENCIA"}}}
          ]},
          {"codi_linia": 7, "nom_linia": "7", "id_sentit": 2, "codi_trajecte": "7001",
           "desti_trajecte": "Fòrum", "propers_busos": [
            {"temps_arribada": 1700000300000, "id_bus": 900}
          ]}
        ]}]}
        """
        let arrivals = try BusParser.arrivals(from: Data(json.utf8), stopCode: 1234)
        XCTAssertEqual(arrivals.count, 4, "every line serving the stop must survive the parse")

        let withoutBus = try XCTUnwrap(arrivals.first { $0.busID == nil })
        XCTAssertEqual(withoutBus.lineName, "H12")
        XCTAssertEqual(withoutBus.seconds, 60)
        XCTAssertEqual(withoutBus.rampStatus, "RATLLADA")
        // Any known state other than SENSE_INCIDENCIA is an incidence, and a
        // missing ramp report is unknown, not broken.
        XCTAssertEqual(withoutBus.rampOperational, false)

        let unknownRamp = try XCTUnwrap(arrivals.first { $0.busID == 77 })
        XCTAssertNil(unknownRamp.rampStatus)
        XCTAssertNil(unknownRamp.rampOperational)
        // A bus already due clamps to zero instead of a negative countdown.
        XCTAssertEqual(unknownRamp.seconds, 0)

        let other = try XCTUnwrap(arrivals.first { $0.lineCode == 7 })
        XCTAssertEqual(other.lineName, "7")
        XCTAssertEqual(other.directionID, 2)
        XCTAssertEqual(other.destination, "Fòrum")
        XCTAssertEqual(other.seconds, 300)
    }

    // MARK: - Alerts (S7)

    func testBusAlertsMapTheAffectedLinesStopsAndText() throws {
        let alerts = try BusAlertParser.alerts(from: Fixtures.data("alerts-bus"))
        XCTAssertEqual(alerts.count, 6)
        // `id` arrives as a JSON number and must be usable as a String key.
        XCTAssertEqual(alerts.first?.id, "126095")

        let detour = try XCTUnwrap(alerts.first { $0.id == "134760" })
        // lineCodes is the numeric lineId, not the commercial name.
        XCTAssertEqual(detour.lineCodes, ["212"])
        XCTAssertEqual(detour.stationCodes, [385, 795])
        XCTAssertEqual(detour.stationNames, ["Gran Via - Bilbao", "Gran Via - Llacuna"])
        XCTAssertEqual(detour.typeName, "Modificació del recorregut amb anul·lació de parada/es i amb parades alternatives existents")
        XCTAssertEqual(detour.effectType, "ALTERATION")
        XCTAssertNil(detour.effectCode)
        XCTAssertEqual(detour.beginDate, Date(timeIntervalSince1970: 1_773_183_600))
        XCTAssertEqual(detour.endDate, Date(timeIntervalSince1970: 1_893_452_400))
        XCTAssertEqual(
            detour.text?.hasPrefix("A partir d'aquesta data, la línia H12 canvia el recorregut temporalment"),
            true
        )
        XCTAssertEqual(detour.entranceNames, [])
    }

    func testBusAlertsDeduplicateRepeatedStopsAndLines() throws {
        let alerts = try BusAlertParser.alerts(from: Fixtures.data("alerts-bus"))
        // The same stop is listed once per way it is affected by.
        let twiceListed = try XCTUnwrap(alerts.first { $0.id == "132775" })
        XCTAssertEqual(twiceListed.stationCodes, [1618])
        XCTAssertEqual(twiceListed.stationNames, ["Carrer número 4 - Carrer F"])
        XCTAssertEqual(twiceListed.lineCodes, ["21", "109"])

        let v17 = try XCTUnwrap(alerts.first { $0.id == "134923" })
        XCTAssertEqual(v17.lineCodes, ["217"])
        XCTAssertEqual(v17.stationCodes, [9633])

        for alert in alerts {
            XCTAssertFalse(alert.lineCodes.isEmpty, "alert \(alert.id) lost its lines")
            XCTAssertEqual(Set(alert.lineCodes).count, alert.lineCodes.count)
            XCTAssertEqual(Set(alert.stationCodes).count, alert.stationCodes.count)
            XCTAssertNotNil(alert.text, "alert \(alert.id) lost its channelInfoTO text")
            XCTAssertNotNil(alert.beginDate)
            XCTAssertNotNil(alert.endDate)
            XCTAssertNotNil(alert.typeName)
        }
    }

    func testBusAlertTypeNamesDriveTheIncidentKind() throws {
        // The parser keeps typeName verbatim; the incident index is what reads
        // the kind out of it (see IncidentIndexTests).
        let alerts = try BusAlertParser.alerts(from: Fixtures.data("alerts-bus"))
        let typeNames = Set(alerts.compactMap(\.typeName))
        XCTAssertTrue(typeNames.contains("Parada anul·lada amb parada alternativa nova"))
        XCTAssertTrue(typeNames.contains("Parada anul·lada sense parada alternativa"))
        XCTAssertEqual(alerts.filter { $0.effectType == "ALTERATION" }.count, 6)
    }
}
