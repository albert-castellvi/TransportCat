import XCTest
@testable import TransportCat

/// Parser of the TMB planner (`DOC-TMB/planer.json`, spec S16). The fixtures
/// are shaped exactly like the documented OpenTripPlanner schema: `plan.
/// itineraries[]` with `legs[]`, epoch-millisecond times, OTP `mode` strings,
/// `route`/`routeColor`/`routeTextColor`, `from`/`to` places,
/// `intermediateStops` and an encoded `legGeometry.points`.
final class PlannerParserTests: XCTestCase {
    // Epoch seconds of 2026-11-02 in Europe/Madrid, the fixture's reference day.
    private static let madridTimeZone = TimeZone(identifier: "Europe/Madrid")!
    private static let madridCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Madrid")!
        return calendar
    }()

    private func parse(_ fixture: String) throws -> [Itinerary] {
        try PlannerParser.itineraries(from: Fixtures.data(fixture))
    }

    private func date(_ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 11
        components.day = 2
        components.hour = hour
        components.minute = minute
        components.second = second
        return Self.madridCalendar.date(from: components)!
    }

    // MARK: - Itineraries

    func testParsesBothItinerariesInOrder() throws {
        let itineraries = try parse("planner-plan")

        XCTAssertEqual(itineraries.count, 2)
        XCTAssertEqual(itineraries[0].legs.count, 5)
        XCTAssertEqual(itineraries[1].legs.count, 3)
        XCTAssertEqual(itineraries[0].duration, 1450, accuracy: 1)
        XCTAssertEqual(itineraries[0].transfers, 1)
        XCTAssertEqual(itineraries[1].transfers, 0)
    }

    func testItineraryTimesAreEpochMilliseconds() throws {
        let itinerary = try XCTUnwrap(parse("planner-plan").first)

        XCTAssertEqual(itinerary.startTime, date(8, 5))
        XCTAssertEqual(itinerary.endTime, date(8, 29, 10))
        XCTAssertEqual(itinerary.walkTime, 270, accuracy: 1)
    }

    func testLegsCarryModeRouteAndColors() throws {
        let itinerary = try XCTUnwrap(parse("planner-plan").first)
        let metroLeg = itinerary.legs[1]

        XCTAssertEqual(itinerary.legs[0].mode, "WALK")
        XCTAssertTrue(itinerary.legs[0].isWalk)
        XCTAssertFalse(itinerary.legs[0].isTransit)
        XCTAssertNil(itinerary.legs[0].route)

        XCTAssertEqual(metroLeg.mode, "SUBWAY")
        XCTAssertEqual(metroLeg.route, "L1")
        XCTAssertEqual(metroLeg.routeColorHex, "CE1126")
        XCTAssertEqual(metroLeg.routeTextColorHex, "FFFFFF")
        XCTAssertEqual(metroLeg.headsign, "Fondo")
        XCTAssertEqual(metroLeg.agencyName, "TMB")
        XCTAssertTrue(metroLeg.isTransit)
        XCTAssertEqual(metroLeg.startTime, date(8, 8, 30))
        XCTAssertEqual(metroLeg.endTime, date(8, 18, 30))
        XCTAssertEqual(try XCTUnwrap(metroLeg.distance), 2400.5, accuracy: 0.01)
    }

    func testLegEndsAndIntermediateStops() throws {
        let itinerary = try XCTUnwrap(parse("planner-plan").first)
        let metroLeg = itinerary.legs[1]

        XCTAssertEqual(metroLeg.from.name, "Catalunya")
        XCTAssertEqual(metroLeg.to.name, "Glòries")
        XCTAssertEqual(metroLeg.from.position, GeoPoint(latitude: 41.3866, longitude: 2.1641))
        XCTAssertEqual(metroLeg.intermediateStops.map(\.name), ["Urquinaona", "Arc de Triomf", "Tetuan"])
        XCTAssertEqual(metroLeg.intermediateStops.first?.code, "161")
        XCTAssertEqual(metroLeg.intermediateStops[2].position.latitude, 41.3977, accuracy: 1e-6)
    }

    func testLegGeometryIsDecodedFromTheEncodedPolyline() throws {
        let itinerary = try XCTUnwrap(parse("planner-plan").first)
        let metroLeg = itinerary.legs[1]

        XCTAssertEqual(metroLeg.geometry.count, 5)
        let first = try XCTUnwrap(metroLeg.geometry.first)
        let last = try XCTUnwrap(metroLeg.geometry.last)
        XCTAssertEqual(first.latitude, 41.3866, accuracy: 1e-6)
        XCTAssertEqual(first.longitude, 2.1641, accuracy: 1e-6)
        XCTAssertEqual(last.latitude, 41.4036, accuracy: 1e-6)
        XCTAssertEqual(last.longitude, 2.1844, accuracy: 1e-6)
    }

    func testBusLegUsesItsPublishedTextColorAndLongName() throws {
        let busLeg = try XCTUnwrap(parse("planner-plan").last?.legs.first { $0.mode == "BUS" })

        XCTAssertEqual(busLeg.route, "7")
        XCTAssertEqual(busLeg.routeLongName, "Viatge Express")
        XCTAssertEqual(busLeg.routeColorHex, "F0ED1E")
        XCTAssertEqual(busLeg.routeTextColorHex, "000000")
        XCTAssertEqual(busLeg.intermediateStops.count, 3)
    }

    func testMinimalLegWithoutOptionalFieldsParses() throws {
        let json = """
        {"plan": {"itineraries": [{
            "startTime": 1793603100000, "endTime": 1793603220000, "duration": 120, "transfers": 0,
            "legs": [{
                "startTime": 1793603100000, "endTime": 1793603220000, "mode": "WALK",
                "from": {"name": "A", "lat": 41.38, "lon": 2.16},
                "to": {"name": "B", "lat": 41.39, "lon": 2.17}
            }]
        }]}}
        """
        let itineraries = try PlannerParser.itineraries(from: Data(json.utf8))

        XCTAssertEqual(itineraries.count, 1)
        let leg = try XCTUnwrap(itineraries[0].legs.first)
        XCTAssertTrue(leg.isWalk)
        XCTAssertEqual(leg.distance, nil)
        XCTAssertEqual(leg.geometry, [])
        XCTAssertEqual(leg.intermediateStops, [])
    }

    // MARK: - Error payloads

    func testPathNotFoundErrorIsNoRoute() throws {
        XCTAssertThrowsError(try parse("planner-no-route")) { error in
            XCTAssertEqual(error as? PlannerError, .noRoute)
        }
    }

    func testEmptyItineraryListIsNoRoute() throws {
        XCTAssertThrowsError(try parse("planner-empty-plan")) { error in
            XCTAssertEqual(error as? PlannerError, .noRoute)
        }
    }

    func testNoTransitTimesErrorIsNoRoute() throws {
        let json = #"{"error": {"id": 404, "msg": "No transit times", "message": "NO_TRANSIT_TIMES"}}"#
        XCTAssertThrowsError(try PlannerParser.itineraries(from: Data(json.utf8))) { error in
            XCTAssertEqual(error as? PlannerError, .noRoute)
        }
    }

    func testSystemErrorIsCalculationFailure() throws {
        XCTAssertThrowsError(try parse("planner-system-error")) { error in
            XCTAssertEqual(error as? PlannerError, .failed)
        }
    }

    func testMissingPlanIsUnexpectedPayload() throws {
        XCTAssertThrowsError(try PlannerParser.itineraries(from: Data(#"{"foo": 1}"#.utf8))) { error in
            guard case TMBError.unexpectedPayload = error else {
                return XCTFail("expected unexpectedPayload, got \(error)")
            }
        }
    }

    func testGarbageIsUnexpectedPayload() throws {
        XCTAssertThrowsError(try PlannerParser.itineraries(from: Data("nope".utf8))) { error in
            guard case TMBError.unexpectedPayload = error else {
                return XCTFail("expected unexpectedPayload, got \(error)")
            }
        }
    }

    // MARK: - Request parameters

    func testRequestQueryMatchesTheDocumentedFormat() throws {
        let query = PlannerParser.requestParameters(
            from: GeoPoint(latitude: 41.3873, longitude: 2.1686),
            to: GeoPoint(latitude: 41.4102, longitude: 2.2045),
            date: date(8, 5),
            arriveBy: false,
            calendar: Self.madridCalendar
        )
        let values = Dictionary(uniqueKeysWithValues: query)

        XCTAssertEqual(values["fromPlace"], "41.387300,2.168600")
        XCTAssertEqual(values["toPlace"], "41.410200,2.204500")
        XCTAssertEqual(values["date"], "11-02-2026")
        XCTAssertEqual(values["time"], "8:05am")
        XCTAssertEqual(values["arriveBy"], "false")
        XCTAssertEqual(values["mode"], "TRANSIT,WALK")
        XCTAssertEqual(values["showIntermediateStops"], "true")
    }

    func testArriveByTrueFlipsTheFlag() throws {
        let query = PlannerParser.requestParameters(
            from: GeoPoint(latitude: 41.4, longitude: 2.2),
            to: GeoPoint(latitude: 41.38, longitude: 2.16),
            date: date(18, 30),
            arriveBy: true,
            calendar: Self.madridCalendar
        )
        let values = Dictionary(uniqueKeysWithValues: query)

        XCTAssertEqual(values["arriveBy"], "true")
        XCTAssertEqual(values["time"], "6:30pm")
    }

    func testClockBoundariesFormatAs12amAnd12pm() throws {
        func timeString(_ hour: Int, _ minute: Int) -> String {
            let query = PlannerParser.requestParameters(
                from: GeoPoint(latitude: 41.4, longitude: 2.2),
                to: GeoPoint(latitude: 41.38, longitude: 2.16),
                date: date(hour, minute),
                arriveBy: false,
                calendar: Self.madridCalendar
            )
            return Dictionary(uniqueKeysWithValues: query)["time"] ?? ""
        }

        XCTAssertEqual(timeString(0, 0), "12:00am")
        XCTAssertEqual(timeString(0, 30), "12:30am")
        XCTAssertEqual(timeString(12, 0), "12:00pm")
        XCTAssertEqual(timeString(13, 5), "1:05pm")
        XCTAssertEqual(timeString(23, 59), "11:59pm")
    }

    func testCoordinatesCarrySigns() throws {
        let query = PlannerParser.requestParameters(
            from: GeoPoint(latitude: -33.5, longitude: -70.25),
            to: GeoPoint(latitude: 40.7, longitude: 2.15),
            date: date(9, 0),
            arriveBy: false,
            calendar: Self.madridCalendar
        )
        let values = Dictionary(uniqueKeysWithValues: query)

        XCTAssertEqual(values["fromPlace"], "-33.500000,-70.250000")
        XCTAssertEqual(values["toPlace"], "40.700000,2.150000")
    }

    // MARK: - Map bounds

    func testBoundsCoverAllPoints() throws {
        let points = [
            GeoPoint(latitude: 41.38, longitude: 2.16),
            GeoPoint(latitude: 41.41, longitude: 2.21),
            GeoPoint(latitude: 41.39, longitude: 2.14),
        ]
        let bounds = try XCTUnwrap(PlannerParser.bounds(of: points))

        XCTAssertEqual(bounds.minLatitude, 41.38, accuracy: 1e-9)
        XCTAssertEqual(bounds.maxLatitude, 41.41, accuracy: 1e-9)
        XCTAssertEqual(bounds.minLongitude, 2.14, accuracy: 1e-9)
        XCTAssertEqual(bounds.maxLongitude, 2.21, accuracy: 1e-9)
    }

    func testBoundsOfNoPointsAreNil() {
        XCTAssertNil(PlannerParser.bounds(of: []))
    }

    // MARK: - Catalan labels

    func testMinuteRounding() {
        XCTAssertEqual(PlannerFormat.minutes(seconds: 1450), 24)
        XCTAssertEqual(PlannerFormat.minutes(seconds: 270), 5)
        XCTAssertEqual(PlannerFormat.minutes(seconds: 30), 1)
        XCTAssertEqual(PlannerFormat.minutes(seconds: 0), 0)
    }

    func testTotalAndWalkingLabels() {
        XCTAssertEqual(PlannerFormat.totalLabel(seconds: 1450), "24 min")
        XCTAssertEqual(PlannerFormat.walkingLabel(seconds: 270), "5 min a peu")
    }

    func testTransfersLabelIsGrammatical() {
        XCTAssertEqual(PlannerFormat.transfersLabel(0), "Sense transbords")
        XCTAssertEqual(PlannerFormat.transfersLabel(1), "1 transbord")
        XCTAssertEqual(PlannerFormat.transfersLabel(2), "2 transbords")
    }

    func testTimeLabelsUseTheGivenTimeZone() {
        XCTAssertEqual(
            PlannerFormat.timeLabel(date(8, 5), timeZone: Self.madridTimeZone),
            "8:05"
        )
        XCTAssertEqual(
            PlannerFormat.timeLabel(date(14, 7), timeZone: Self.madridTimeZone),
            "14:07"
        )
        XCTAssertEqual(
            PlannerFormat.timeRangeLabel(start: date(8, 5), end: date(8, 29), timeZone: Self.madridTimeZone),
            "8:05 – 8:29"
        )
    }

    func testModeLabelsAreCatalan() {
        XCTAssertEqual(PlannerFormat.modeLabel("WALK"), "A peu")
        XCTAssertEqual(PlannerFormat.modeLabel("SUBWAY"), "Metro")
        XCTAssertEqual(PlannerFormat.modeLabel("BUS"), "Bus")
        XCTAssertEqual(PlannerFormat.modeLabel("TRAM"), "Tramvia")
        XCTAssertEqual(PlannerFormat.modeLabel("RAIL"), "Tren")
        XCTAssertEqual(PlannerFormat.modeLabel("CAR"), "CAR")
    }
}
