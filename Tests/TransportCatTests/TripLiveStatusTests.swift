import XCTest
@testable import TransportCat

/// Live per-leg status of an active trip (spec S4): the honest rules — never
/// invent a time, "segons horari" where only the timetable exists, FGC position
/// wording only — tested on the pure builders and wording, away from the
/// network.
final class TripLiveStatusTests: XCTestCase {
    private let timeZone = TimeZone(identifier: "Europe/Madrid")!

    /// A Wednesday at 10:40 local time.
    private var now: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = DateComponents(year: 2026, month: 11, day: 18, hour: 10, minute: 40)
        return calendar.date(from: components)!
    }

    // MARK: - Metro

    private func metro(_ destination: String, seconds: Int?, via: Int? = nil) -> Arrival {
        Arrival(
            stationCode: 123,
            lineCode: "1",
            destination: destination,
            seconds: seconds,
            rawText: seconds.map { "\($0 / 60) min" } ?? "",
            via: via
        )
    }

    func testMetroKeepsTheLegDirectionIgnoringCaseAndDiacritics() {
        let arrivals = [
            metro("Hospital de Bellvitge", seconds: 120),
            metro("FONDO", seconds: 180),
            metro("Fundó", seconds: 240),
        ]
        let live = TripLegLiveBuilder.metro(arrivals: arrivals, headsign: "fondo", now: now)
        guard case .departures(let dates, let isRealTime) = live else {
            return XCTFail("expected departures, got \(live)")
        }
        XCTAssertTrue(isRealTime, "i-Metro countdowns are live")
        // "Fundó" is another destination: only the Fondo train is kept.
        XCTAssertEqual(dates, [now.addingTimeInterval(180)])
    }

    func testMetroFallsBackToEveryArrivalWhenNoDestinationMatches() {
        let arrivals = [
            metro("Barcelona - Fondo", seconds: 300),
            metro("Aeroport", seconds: 90),
            metro("Fondo", seconds: 600),
        ]
        let live = TripLegLiveBuilder.metro(arrivals: arrivals, headsign: "Sabadell", now: now)
        guard case .departures(let dates, _) = live else {
            return XCTFail("expected departures, got \(live)")
        }
        XCTAssertEqual(dates.count, 3, "a fallback keeps the soonest arrivals of every direction")
        XCTAssertEqual(dates.first, now.addingTimeInterval(90), "sorted soonest first")
    }

    func testMetroKeepsAtMostThreeSoonestDepartures() {
        let arrivals = [
            metro("Fondo", seconds: 300),
            metro("Fondo", seconds: 60),
            metro("Fondo", seconds: 240),
            metro("Fondo", seconds: 120),
            metro("Fondo", seconds: 180),
        ]
        let live = TripLegLiveBuilder.metro(arrivals: arrivals, headsign: "Fondo", now: now)
        guard case .departures(let dates, _) = live else {
            return XCTFail("expected departures, got \(live)")
        }
        XCTAssertEqual(dates, [60, 120, 180].map { now.addingTimeInterval(TimeInterval($0)) })
    }

    func testMetroMatchesFullDestinationsTheLegShortens() {
        let arrivals = [metro("Fondo (Barcelona)", seconds: 120), metro("Sant Andreu", seconds: 60)]
        let live = TripLegLiveBuilder.metro(arrivals: arrivals, headsign: "Fondo", now: now)
        guard case .departures(let dates, _) = live else {
            return XCTFail("expected departures, got \(live)")
        }
        XCTAssertEqual(dates, [now.addingTimeInterval(120)])
    }

    // MARK: - Bus

    func testBusCountdownsAreRealTimeAndFollowTheLegDirection() {
        let arrivals = [
            busArrival(line: "H12", destination: "Barcelona - Sant Genís", seconds: 240),
            busArrival(line: "H12", destination: "Provençana", seconds: 60),
        ]
        let live = TripLegLiveBuilder.bus(arrivals: arrivals, headsign: "Provençana", now: now)
        XCTAssertEqual(live, .departures([now.addingTimeInterval(60)], isRealTime: true))
    }

    private func busArrival(line: String, destination: String, seconds: Int) -> BusArrival {
        BusArrival(
            stopCode: 319,
            lineCode: 212,
            lineName: line,
            directionID: 1,
            trajectCode: "1",
            destination: destination,
            seconds: seconds,
            busID: nil,
            rampStatus: nil
        )
    }

    // MARK: - Rodalies

    private func rodalies(offset: Int, line: String = "R2N", delay: Int? = nil, direction: Int = 0) -> RodaliesDeparture {
        RodaliesDeparture(
            tripID: "trip-\(line)-\(offset)-\(direction)",
            lineCode: line,
            direction: direction,
            headsign: "Aeroport",
            scheduledAt: now.addingTimeInterval(TimeInterval(offset)),
            delaySeconds: delay
        )
    }

    func testRodaliesFiltersByLineAndHeadsign() {
        let departures = [
            rodalies(offset: 300, line: "R2"),
            rodalies(offset: 120),
            rodalies(offset: 600),
        ]
        let live = TripLegLiveBuilder.rodalies(
            departures: departures,
            lineCode: "R2N",
            headsign: "Aeroport",
            now: now
        )
        guard case .departures(let dates, _) = live else {
            return XCTFail("expected departures, got \(live)")
        }
        XCTAssertEqual(dates, [now.addingTimeInterval(120), now.addingTimeInterval(600)])
    }

    func testRodaliesFiltersByDirectionWhenTheTopologyKnowsIt() {
        let departures = [
            rodalies(offset: 120, direction: 1),
            rodalies(offset: 240, direction: 0),
        ]
        let live = TripLegLiveBuilder.rodalies(
            departures: departures,
            lineCode: "R2N",
            headsign: "Aeroport",
            direction: 0,
            now: now
        )
        XCTAssertEqual(live, .departures([now.addingTimeInterval(240)], isRealTime: false))
    }

    func testRodaliesIsRealTimeOnlyWithADelayAndUsesTheExpectedTime() {
        // One train 3 min out and 4 min late → leaves in 7 min; one on time at
        // the same 7 min.
        let departures = [rodalies(offset: 180, delay: 240), rodalies(offset: 420)]
        let live = TripLegLiveBuilder.rodalies(
            departures: departures,
            lineCode: "R2N",
            headsign: "Aeroport",
            now: now
        )
        XCTAssertEqual(
            live,
            .departures([now.addingTimeInterval(420), now.addingTimeInterval(420)], isRealTime: true),
            "180 s + 240 s delay = 420 s, and a delay makes the board realtime"
        )

        let timetableOnly = TripLegLiveBuilder.rodalies(
            departures: [rodalies(offset: 420)],
            lineCode: "R2N",
            headsign: "Aeroport",
            now: now
        )
        XCTAssertEqual(timetableOnly, .departures([now.addingTimeInterval(420)], isRealTime: false))
    }

    // MARK: - FGC

    private func fgcTrain(
        id: String,
        line: String = "S1",
        next: [String],
        stoppedAt: String? = nil,
        onTime: Bool = true
    ) -> FGCTrain {
        FGCTrain(
            id: id,
            lineCode: line,
            direction: "A",
            originCode: "PL",
            destinationCode: "SC",
            destinationName: nil,
            position: GeoPoint(latitude: 0, longitude: 0),
            nextStopCodes: next,
            isOnTime: onTime,
            stoppedAtStopCode: stoppedAt,
            unitType: nil,
            occupancy: []
        )
    }

    func testFGCTrainAtThePlatform() {
        // A stopped train no longer lists its own station (live feed shape).
        let trains = [fgcTrain(id: "1", next: ["SG", "MN", "SC"], stoppedAt: "GR", onTime: false)]
        let live = TripLegLiveBuilder.fgc(trains: trains, lineCode: "S1", fromCode: "GR", toCode: "SC")
        guard case .fgc(let fgc) = live else { return XCTFail("expected FGC, got \(live)") }
        XCTAssertEqual(fgc, FGCLegLive(atPlatform: true, stopsAway: nil, isOnTime: false, trainCount: 1))
    }

    func testFGCApproachingTrainCountsTheStops() {
        let trains = [
            fgcTrain(id: "far", next: ["BC", "GR", "SC"]),
            fgcTrain(id: "near", next: ["GR", "SC"], onTime: false),
        ]
        let live = TripLegLiveBuilder.fgc(trains: trains, lineCode: "S1", fromCode: "GR", toCode: "SC")
        guard case .fgc(let fgc) = live else { return XCTFail("expected FGC, got \(live)") }
        XCTAssertEqual(fgc.atPlatform, false)
        XCTAssertEqual(fgc.stopsAway, 0)
        XCTAssertEqual(fgc.trainCount, 2)
        XCTAssertEqual(fgc.isOnTime, false, "the nearest train is the one without stops in between")

        let further = TripLegLiveBuilder.fgc(
            trains: [fgcTrain(id: "far", next: ["BC", "GR", "SC"])],
            lineCode: "S1",
            fromCode: "GR",
            toCode: "SC"
        )
        guard case .fgc(let oneStop) = further else { return XCTFail("expected FGC, got \(further)") }
        XCTAssertEqual(oneStop.stopsAway, 1)
    }

    func testFGCOtherLineServingTheLegCounts() {
        // Gràcia → Sant Cugat: an S2 serves a leg the planner drew as S1.
        let trains = [fgcTrain(id: "s2", line: "S2", next: ["GR", "SC"])]
        let live = TripLegLiveBuilder.fgc(trains: trains, lineCode: "S1", fromCode: "GR", toCode: "SC")
        guard case .fgc(let fgc) = live else { return XCTFail("expected FGC, got \(live)") }
        XCTAssertEqual(fgc.trainCount, 1)
        XCTAssertEqual(fgc.stopsAway, 0)
    }

    func testFGCNoTrainInDirect() {
        let trains = [
            fgcTrain(id: "after", next: ["SC", "GR"]),
            fgcTrain(id: "stopped", next: ["GR"], stoppedAt: "GR"),
        ]
        let live = TripLegLiveBuilder.fgc(trains: trains, lineCode: "S1", fromCode: "GR", toCode: "SC")
        guard case .fgc(let fgc) = live else { return XCTFail("expected FGC, got \(live)") }
        XCTAssertEqual(fgc, FGCLegLive(atPlatform: false, stopsAway: nil, isOnTime: nil, trainCount: 0))
    }

    func testFGCWrongDirectionIsNotServing() {
        // Stops the boarding station only after the destination: the train is
        // running the other way to this leg.
        let trains = [
            fgcTrain(id: "reverse", next: ["SC", "GR"]),
            fgcTrain(id: "skipDestination", next: ["GR", "BC"]),
        ]
        let live = TripLegLiveBuilder.fgc(trains: trains, lineCode: "S1", fromCode: "GR", toCode: "SC")
        guard case .fgc(let fgc) = live else { return XCTFail("expected FGC, got \(live)") }
        XCTAssertEqual(fgc.trainCount, 0)
        XCTAssertNil(fgc.stopsAway)
        XCTAssertFalse(fgc.atPlatform)
    }

    func testFGCStoppedTrainWhoseNextStopsMissTheDestinationIsNotServing() {
        let trains = [fgcTrain(id: "wrongBranch", next: ["BC"], stoppedAt: "GR")]
        let live = TripLegLiveBuilder.fgc(trains: trains, lineCode: "S1", fromCode: "GR", toCode: "SC")
        guard case .fgc(let fgc) = live else { return XCTFail("expected FGC, got \(live)") }
        XCTAssertEqual(fgc.trainCount, 0)
    }

    func testFGCLineAliasResolvesToItsBaseLine() {
        let trains = [fgcTrain(id: "R5R", line: "R5R", next: ["GR", "SC"])]
        let live = TripLegLiveBuilder.fgc(trains: trains, lineCode: "R5", fromCode: "GR", toCode: "SC")
        guard case .fgc(let fgc) = live else { return XCTFail("expected FGC, got \(live)") }
        XCTAssertEqual(fgc.trainCount, 1)
    }

    // MARK: - Wording

    private var clockPattern: String { "\\d{2}:\\d{2}" }

    private func wording(_ live: TripLegLive, plannedDeparture: Date? = nil) -> TripLegWording.Wording {
        TripLegWording.wording(for: live, now: now, plannedDeparture: plannedDeparture, timeZone: timeZone)
    }

    func testWordingRealtimeMinutesAndFollowingTrains() {
        let live = TripLegLive.departures(
            [now.addingTimeInterval(180), now.addingTimeInterval(420), now.addingTimeInterval(660)],
            isRealTime: true
        )
        let result = wording(live)
        XCTAssertEqual(result.big, "3 min")
        XCTAssertEqual(result.small, "després 7 i 11 min")
    }

    func testWordingRealtimeSaysAraWithinAMinute() {
        let live = TripLegLive.departures([now.addingTimeInterval(30), now.addingTimeInterval(400)], isRealTime: true)
        XCTAssertEqual(wording(live).big, "ara")
        XCTAssertEqual(wording(TripLegLive.departures([now], isRealTime: true)).big, "ara")
    }

    func testWordingTimetableShowsTheClockAndSaysSo() {
        let departure = now.addingTimeInterval(6 * 60)
        let live = TripLegLive.departures([departure], isRealTime: false)
        let result = wording(live)
        XCTAssertEqual(result.big, "10:46")
        XCTAssertEqual(result.small, "segons horari")
    }

    func testFGCPositionWording() {
        let platform = wording(.fgc(FGCLegLive(atPlatform: true, stopsAway: nil, isOnTime: true, trainCount: 1)))
        XCTAssertEqual(platform.big, "Ja hi és")
        XCTAssertEqual(platform.small, "a l'andana · en hora")

        let platformLate = wording(.fgc(FGCLegLive(atPlatform: true, stopsAway: nil, isOnTime: false, trainCount: 1)))
        XCTAssertEqual(platformLate.small, "a l'andana · amb retard")

        XCTAssertEqual(wording(.fgc(FGCLegLive(atPlatform: false, stopsAway: 1, isOnTime: true, trainCount: 1))).big, "a 1 parada")
        XCTAssertEqual(wording(.fgc(FGCLegLive(atPlatform: false, stopsAway: 3, isOnTime: true, trainCount: 1))).big, "a 3 parades")

        let none = wording(.fgc(FGCLegLive(atPlatform: false, stopsAway: nil, isOnTime: nil, trainCount: 0)))
        XCTAssertEqual(none.big, "—")
        XCTAssertEqual(none.small, "cap tren en directe")
    }

    func testFGCWordingNeverInventsAClockTime() {
        let cases: [FGCLegLive] = [
            FGCLegLive(atPlatform: true, stopsAway: nil, isOnTime: true, trainCount: 1),
            FGCLegLive(atPlatform: true, stopsAway: nil, isOnTime: false, trainCount: 1),
            FGCLegLive(atPlatform: false, stopsAway: 1, isOnTime: true, trainCount: 1),
            FGCLegLive(atPlatform: false, stopsAway: 4, isOnTime: false, trainCount: 2),
            FGCLegLive(atPlatform: false, stopsAway: nil, isOnTime: nil, trainCount: 0),
        ]
        for fgc in cases {
            let result = wording(.fgc(fgc))
            XCTAssertNil(result.big.range(of: clockPattern, options: .regularExpression), result.big)
            XCTAssertNil(result.small.range(of: clockPattern, options: .regularExpression), result.small)
        }
    }

    func testPlannedWordingSaysPlanned() {
        let departure = now.addingTimeInterval(6 * 60)
        let result = wording(.planned, plannedDeparture: departure)
        XCTAssertEqual(result.big, "10:46")
        XCTAssertEqual(result.small, "segons planificació")
    }

    func testEmptyDepartureBoardFallsBackToThePlannedTime() {
        let departure = now.addingTimeInterval(6 * 60)
        let result = wording(.departures([], isRealTime: true), plannedDeparture: departure)
        XCTAssertEqual(result.big, "10:46")
        XCTAssertEqual(result.small, "segons planificació")
    }

    // MARK: - Live phase

    private func trip(legs: [SavedTripLeg], finalWalk: Int = 120, plannedDuration: Int) -> SavedTrip {
        SavedTrip(
            name: "Rocafort → Sant Cugat",
            originName: "Rocafort",
            destinationName: "Sant Cugat",
            origin: GeoPoint(latitude: 0, longitude: 0),
            destination: GeoPoint(latitude: 0, longitude: 0),
            kind: .saved,
            createdAt: now,
            legs: legs,
            finalWalkSeconds: finalWalk,
            plannedDurationSeconds: plannedDuration
        )
    }

    private func leg(
        _ operatorKind: TripOperator,
        line: String,
        ride: Int,
        walk: Int,
        from: String? = "GR",
        to: String? = "SC"
    ) -> SavedTripLeg {
        SavedTripLeg(
            operatorKind: operatorKind,
            lineCode: line,
            lineName: line,
            colorHex: nil,
            textColorHex: nil,
            headsign: nil,
            fromName: from ?? "",
            toName: to ?? "",
            fromStationID: from,
            toStationID: to,
            fromPosition: GeoPoint(latitude: 0, longitude: 0),
            toPosition: GeoPoint(latitude: 0, longitude: 0),
            rideSeconds: ride,
            walkSecondsBefore: walk,
            geometry: []
        )
    }

    func testLivePhaseWaitsUntilTheRealDeparture() {
        let legs = [leg(.metro, line: "1", ride: 900, walk: 300, from: "123", to: "124")]
        let saved = trip(legs: legs, plannedDuration: 1320)
        let first = now.addingTimeInterval(120)

        XCTAssertEqual(TripTiming.livePhase(trip: saved, firstDeparture: first, now: now), .waiting(legIndex: 0))
        XCTAssertEqual(
            TripTiming.livePhase(trip: saved, firstDeparture: first, now: first.addingTimeInterval(300)),
            .riding(legIndex: 0)
        )
        // The ride lands at +1050 and the final walk closes the trip: before
        // the real departure the rider is still waiting.
        XCTAssertEqual(
            TripTiming.livePhase(trip: saved, firstDeparture: first, now: now.addingTimeInterval(60)),
            .waiting(legIndex: 0)
        )
    }
}
