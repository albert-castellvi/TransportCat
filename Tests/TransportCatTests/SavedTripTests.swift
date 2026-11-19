import XCTest
@testable import TransportCat

/// Maps planner itineraries to saved trips (spec S4): operator and line
/// resolution, the station ids the live sources use, the walking split and the
/// signature that deduplicates trips. The fixtures are real planner answers:
/// Rocafort → Sant Cugat (metro L1/L3 + FGC S1/S2 + TMB and Avanza buses) and
/// Sants → Aeroport (Renfe R2N + metro L9S, Monbus Aerobús).
final class SavedTripTests: XCTestCase {
    private static let rocafortEndpoint = GeoPoint(latitude: 41.3787, longitude: 2.1546)
    private static let destination = GeoPoint(latitude: 41.473, longitude: 2.0817)
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func itineraries(_ fixture: String) throws -> [Itinerary] {
        try PlannerParser.itineraries(from: Fixtures.data(fixture))
    }

    private func trip(
        _ itinerary: Itinerary,
        kind: TripKind = .saved,
        originName: String = "Rocafort",
        destinationName: String = "Sant Cugat Centre"
    ) throws -> SavedTrip {
        try XCTUnwrap(
            SavedTrip(
                itinerary: itinerary,
                originName: originName,
                destinationName: destinationName,
                origin: Self.rocafortEndpoint,
                destination: Self.destination,
                kind: kind,
                now: Self.now
            )
        )
    }

    // MARK: - Rocafort → Sant Cugat (L1 + L3 + S1)

    func testMetroAndFGCItineraryMapsToThreeRides() throws {
        let saved = try trip(try itineraries("planner-rocafort-santcugat")[1])

        XCTAssertEqual(saved.legs.map(\.operatorKind), [.metro, .metro, .fgc])
        XCTAssertEqual(saved.legs.map(\.lineCode), ["1", "3", "S1"])
        XCTAssertEqual(saved.legs.map(\.lineName), ["L1", "L3", "S1"])
        XCTAssertEqual(saved.name, "Rocafort → Sant Cugat Centre")
        XCTAssertEqual(saved.kind, .saved)
        XCTAssertEqual(saved.createdAt, Self.now)
        XCTAssertNil(saved.lastUsedAt)
        XCTAssertEqual(saved.origin, Self.rocafortEndpoint)
        XCTAssertEqual(saved.destination, Self.destination)
    }

    func testFirstMetroLegKeepsItsStationsAndHeadsign() throws {
        let first = try trip(try itineraries("planner-rocafort-santcugat")[1]).legs[0]

        XCTAssertEqual(first.fromName, "Rocafort")
        XCTAssertEqual(first.toName, "Catalunya")
        XCTAssertEqual(first.fromStationID, "123")
        XCTAssertEqual(first.toStationID, "126")
        XCTAssertEqual(first.headsign, "Fondo")
        XCTAssertEqual(first.colorHex, "CE1126")
        XCTAssertNotNil(first.textColorHex)
        XCTAssertEqual(first.rideSeconds, 217)
        XCTAssertEqual(first.walkSecondsBefore, 167)
        XCTAssertEqual(first.fromPosition, GeoPoint(latitude: 41.379232, longitude: 2.154562))
        XCTAssertFalse(first.geometry.isEmpty)
    }

    func testTransferLegsCarryTheWalkBetweenRides() throws {
        let saved = try trip(try itineraries("planner-rocafort-santcugat")[1])

        let l3 = saved.legs[1]
        XCTAssertEqual(l3.fromName, "Catalunya")
        XCTAssertEqual(l3.toName, "Fontana")
        XCTAssertEqual(l3.fromStationID, "326")
        XCTAssertEqual(l3.headsign, "Trinitat Nova")
        // The metro-to-metro walk at Catalunya.
        XCTAssertEqual(l3.walkSecondsBefore, 45)
        XCTAssertEqual(l3.rideSeconds, 282)
    }

    func testFGCLegUsesTheStationCodeWithoutThePlatformDigit() throws {
        let fgc = try XCTUnwrap(try trip(try itineraries("planner-rocafort-santcugat")[1]).legs.last)

        XCTAssertEqual(fgc.operatorKind, .fgc)
        XCTAssertEqual(fgc.lineCode, "S1")
        XCTAssertEqual(fgc.lineName, "S1")
        XCTAssertEqual(fgc.fromName, "Gràcia")
        XCTAssertEqual(fgc.toName, "Sant Cugat Centre")
        // "2:GR1" (stop plus platform) → "GR".
        XCTAssertEqual(fgc.fromStationID, "GR")
        // "2:SC1" → "SC".
        XCTAssertEqual(fgc.toStationID, "SC")
        XCTAssertEqual(fgc.headsign, "Terrassa Nacions Unides")
        XCTAssertEqual(fgc.walkSecondsBefore, 737)
    }

    func testFinalWalkIsTheWalkAfterTheLastRide() throws {
        let saved = try trip(try itineraries("planner-rocafort-santcugat")[1])

        XCTAssertEqual(saved.finalWalkSeconds, 681)
        XCTAssertEqual(saved.plannedDurationSeconds, 4109)
    }

    func testBusLegsResolveTheirOperatorsAndTMBStopCodes() throws {
        let saved = try trip(try itineraries("planner-rocafort-santcugat")[0])

        XCTAssertEqual(saved.legs.map(\.operatorKind), [.bus, .fgc])
        let v9 = saved.legs[0]
        XCTAssertEqual(v9.lineCode, "V9")
        XCTAssertEqual(v9.lineName, "V9")
        // "3:2.319.674897" → the TMB CODI_PARADA "319".
        XCTAssertEqual(v9.fromStationID, "319")
        XCTAssertEqual(v9.toStationID, "3581")
        XCTAssertEqual(v9.headsign, "Sarrià")
        XCTAssertEqual(v9.walkSecondsBefore, 295)
        XCTAssertEqual(saved.legs[1].operatorKind, .fgc)
        XCTAssertEqual(saved.legs[1].fromStationID, "TT")
    }

    /// Avanza publishes a bus line the app cannot follow: it is still a ride,
    /// but as `.other` with no station ids.
    func testAvanzaBusLegIsOther() throws {
        let saved = try trip(try itineraries("planner-rocafort-santcugat")[2])
        let avanza = try XCTUnwrap(saved.legs.first { $0.lineCode == "L95" })

        XCTAssertEqual(avanza.operatorKind, .other)
        XCTAssertNil(avanza.fromStationID)
        XCTAssertNil(avanza.toStationID)
        XCTAssertEqual(avanza.fromName, "Gran Via - Entença")
    }

    // MARK: - Sants → Aeroport (R2N + L9S)

    func testRodaliesAndL9SItineraryMapsToTwoRides() throws {
        let itinerary = try itineraries("planner-sants-aeroport")[0]
        let saved = try XCTUnwrap(
            SavedTrip(
                itinerary: itinerary,
                originName: "Sants",
                destinationName: "Aeroport T1",
                origin: GeoPoint(latitude: 41.3792, longitude: 2.1402),
                destination: GeoPoint(latitude: 41.2878, longitude: 2.0726),
                kind: .habitual,
                now: Self.now
            )
        )

        XCTAssertEqual(saved.legs.count, 2)
        let rodalies = saved.legs[0]
        XCTAssertEqual(rodalies.operatorKind, .rodalies)
        XCTAssertEqual(rodalies.lineCode, "R2N")
        XCTAssertEqual(rodalies.lineName, "R2N")
        XCTAssertEqual(rodalies.fromName, "Barcelona-Sants")
        // "4:71801" → the GTFS stop id "71801".
        XCTAssertEqual(rodalies.fromStationID, "71801")
        XCTAssertEqual(rodalies.toStationID, "71707")

        let l9s = saved.legs[1]
        XCTAssertEqual(l9s.operatorKind, .metro)
        // The screen code of L9S, not the published "L9S".
        XCTAssertEqual(l9s.lineCode, "91")
        XCTAssertEqual(l9s.lineName, "L9S")
        XCTAssertEqual(l9s.fromStationID, "907")
        XCTAssertEqual(l9s.toStationID, "901")
        XCTAssertEqual(l9s.headsign, "Aeroport T1")
        XCTAssertEqual(l9s.walkSecondsBefore, 97)
    }

    func testMonbusAerobusLegIsOther() throws {
        let saved = try trip(try itineraries("planner-sants-aeroport")[1])
        let aerobus = try XCTUnwrap(saved.legs.first { $0.lineCode == "A1" })

        XCTAssertEqual(aerobus.operatorKind, .other)
        XCTAssertEqual(aerobus.lineName, "A1")
        XCTAssertNil(aerobus.fromStationID)
        XCTAssertEqual(aerobus.walkSecondsBefore, 431)
    }

    // MARK: - Walking and nil cases

    func testItsOwnWalkSequenceSumsIntoEachRide() throws {
        // One walk before, one walk between two rides and one after: the walks
        // land on the ride they precede and on `finalWalkSeconds`.
        let now = Date(timeIntervalSince1970: 0)
        func leg(_ minutes: Double, mode: String = "WALK") -> Leg {
            Leg(
                startTime: now,
                endTime: now.addingTimeInterval(minutes * 60),
                mode: mode,
                route: mode == "WALK" ? nil : "V15",
                routeLongName: nil,
                routeColorHex: nil,
                routeTextColorHex: nil,
                headsign: nil,
                agencyName: mode == "WALK" ? nil : "TMB",
                distance: nil,
                from: LegPlace(name: "A", position: GeoPoint(latitude: 41.38, longitude: 2.16)),
                to: LegPlace(name: "B", position: GeoPoint(latitude: 41.39, longitude: 2.17)),
                intermediateStops: [],
                geometry: [],
                isTransit: mode != "WALK"
            )
        }
        let itinerary = Itinerary(
            duration: 30 * 60,
            startTime: now,
            endTime: now.addingTimeInterval(30 * 60),
            walkTime: 10 * 60,
            transfers: 1,
            legs: [
                leg(120 / 60), leg(150 / 60, mode: "BUS"),
                leg(60 / 60), leg(120 / 60, mode: "BUS"),
                leg(240 / 60),
            ]
        )
        let saved = try trip(itinerary)

        XCTAssertEqual(saved.legs.map(\.walkSecondsBefore), [120, 60])
        XCTAssertEqual(saved.legs.map(\.rideSeconds), [150, 120])
        XCTAssertEqual(saved.finalWalkSeconds, 240)
    }

    func testWalkOnlyItineraryIsNotATrip() throws {
        let itinerary = try XCTUnwrap(try itineraries("planner-plan").first)
        let rides = itinerary.legs.map { leg in
            filledLeg(
                leg,
                start: leg.startTime,
                end: leg.endTime,
                mode: "WALK",
                route: nil,
                agencyName: nil,
                isTransit: false
            )
        }
        let walkOnly = Itinerary(
            duration: itinerary.duration,
            startTime: itinerary.startTime,
            endTime: itinerary.endTime,
            walkTime: itinerary.duration,
            transfers: 0,
            legs: rides
        )

        XCTAssertNil(
            SavedTrip(
                itinerary: walkOnly,
                originName: "A",
                destinationName: "B",
                origin: GeoPoint(latitude: 41.38, longitude: 2.16),
                destination: GeoPoint(latitude: 41.39, longitude: 2.17),
                kind: .recent,
                now: Self.now
            )
        )
    }

    /// A copy of `leg` with new times, mode and route (the planner models are
    /// immutable, so hand-built itineraries are spelled out).
    private func filledLeg(
        _ leg: Leg,
        start: Date,
        end: Date,
        mode: String,
        route: String?,
        agencyName: String?,
        isTransit: Bool
    ) -> Leg {
        Leg(
            startTime: start,
            endTime: end,
            mode: mode,
            route: route,
            routeLongName: nil,
            routeColorHex: nil,
            routeTextColorHex: nil,
            headsign: nil,
            agencyName: agencyName,
            distance: nil,
            from: leg.from,
            to: leg.to,
            intermediateStops: [],
            geometry: [],
            isTransit: isTransit
        )
    }

    // MARK: - Signature and Codable

    func testSignatureIsTheSameForTheSameRides() throws {
        let first = try trip(try itineraries("planner-rocafort-santcugat")[1])
        let again = try trip(try itineraries("planner-rocafort-santcugat")[1], kind: .habitual)
        let other = try trip(try itineraries("planner-rocafort-santcugat")[0])

        XCTAssertNotEqual(first.id, again.id)
        XCTAssertEqual(first.signature, again.signature)
        XCTAssertNotEqual(first.signature, other.signature)
        XCTAssertTrue(first.signature.contains("metro:1:"))
        XCTAssertTrue(first.signature.contains("fgc:S1:"))
    }

    func testCodableRoundTrip() throws {
        let saved = try trip(try itineraries("planner-rocafort-santcugat")[1])

        let data = try JSONEncoder().encode(saved)
        let decoded = try JSONDecoder().decode(SavedTrip.self, from: data)

        XCTAssertEqual(decoded, saved)
    }
}
