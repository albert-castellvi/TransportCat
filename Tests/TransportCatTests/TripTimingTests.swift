import XCTest
@testable import TransportCat

/// `TripTiming` (spec S4): catching the next departure, the planned timeline
/// of a saved trip and the phase it puts the rider in. Pure arithmetic over
/// `Date`, so every boundary is exact.
final class TripTimingTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    /// Two rides with a transfer: walk 2 min, metro 10 min, walk 3 min,
    /// FGC 8 min, final walk 1 min.
    private func trip(legs: [SavedTripLeg]? = nil, finalWalk: Int = 60) -> SavedTrip {
        SavedTrip(
            name: "Rocafort → Sant Cugat Centre",
            originName: "Rocafort",
            destinationName: "Sant Cugat Centre",
            origin: GeoPoint(latitude: 41.38, longitude: 2.16),
            destination: GeoPoint(latitude: 41.47, longitude: 2.08),
            kind: .saved,
            createdAt: start,
            lastUsedAt: nil,
            legs: legs ?? [leg(.metro, "1", walk: 120, ride: 600), leg(.fgc, "S1", walk: 180, ride: 480)],
            finalWalkSeconds: finalWalk,
            plannedDurationSeconds: 1440
        )
    }

    private func leg(_ kind: TripOperator, _ code: String, walk: Int, ride: Int) -> SavedTripLeg {
        SavedTripLeg(
            operatorKind: kind,
            lineCode: code,
            lineName: code,
            colorHex: nil,
            textColorHex: nil,
            headsign: nil,
            fromName: "A",
            toName: "B",
            fromStationID: "1",
            toStationID: "2",
            fromPosition: GeoPoint(latitude: 41.38, longitude: 2.16),
            toPosition: GeoPoint(latitude: 41.39, longitude: 2.17),
            rideSeconds: ride,
            walkSecondsBefore: walk,
            geometry: []
        )
    }

    private func seconds(_ value: TimeInterval) -> Date {
        start.addingTimeInterval(value)
    }

    // MARK: - nextCatchable

    func testNextCatchableIsTheFirstDepartureAtTheMargin() {
        let departure = seconds(120)
        let other = seconds(300)

        // Exactly at earliest + margin: the rider catches it.
        XCTAssertEqual(
            TripTiming.nextCatchable(after: seconds(60), departures: [other, departure]),
            departure
        )
        // One second later: missed.
        XCTAssertEqual(
            TripTiming.nextCatchable(after: seconds(61), departures: [other, departure]),
            other
        )
    }

    func testNextCatchableRespectsACustomMargin() {
        XCTAssertEqual(
            TripTiming.nextCatchable(after: seconds(0), departures: [seconds(60), seconds(90)], margin: 90),
            seconds(90)
        )
    }

    func testNextCatchableWithNoDeparturesIsNil() {
        XCTAssertNil(TripTiming.nextCatchable(after: seconds(0), departures: []))
    }

    func testNextCatchableWhenAllHaveLeftIsNil() {
        XCTAssertNil(TripTiming.nextCatchable(after: seconds(600), departures: [seconds(0), seconds(300)]))
    }

    // MARK: - transferMargin

    func testTransferMarginSubtractsTheWalk() {
        XCTAssertEqual(
            TripTiming.transferMargin(arrival: seconds(0), walkSeconds: 180, departure: seconds(300)),
            120
        )
        XCTAssertEqual(
            TripTiming.transferMargin(arrival: seconds(0), walkSeconds: 300, departure: seconds(300)),
            0
        )
        XCTAssertEqual(
            TripTiming.transferMargin(arrival: seconds(0), walkSeconds: 240, departure: seconds(180)),
            -60
        )
    }

    // MARK: - Planned timeline

    func testPlannedArrivalAddsTheFinalWalk() {
        // 120 + 600 + 180 + 480 + 60.
        XCTAssertEqual(TripTiming.plannedArrival(trip: trip(), startedAt: start), seconds(1440))
    }

    func testTimelineDeparturesAndRideEnds() {
        let timeline = TripTiming.plannedTimeline(trip: trip(), startedAt: start)

        XCTAssertEqual(timeline.departures, [seconds(120), seconds(900)])
        XCTAssertEqual(timeline.reaches, [seconds(720), seconds(1380)])
    }

    func testPhaseAtEachBoundary() {
        let trip = trip()
        func phase(_ offset: TimeInterval) -> TripPhase {
            TripTiming.plannedPhase(trip: trip, startedAt: start, now: seconds(offset))
        }

        XCTAssertEqual(phase(0), .waiting(legIndex: 0))
        XCTAssertEqual(phase(119), .waiting(legIndex: 0))
        // The second the metro leaves, the rider is aboard.
        XCTAssertEqual(phase(120), .riding(legIndex: 0))
        XCTAssertEqual(phase(719), .riding(legIndex: 0))
        XCTAssertEqual(phase(720), .transfer(toLegIndex: 1))
        XCTAssertEqual(phase(899), .transfer(toLegIndex: 1))
        XCTAssertEqual(phase(900), .riding(legIndex: 1))
        XCTAssertEqual(phase(1379), .riding(legIndex: 1))
        // The FGC ride ends: the final walk, which reads as arrived.
        XCTAssertEqual(phase(1380), .arrived)
        XCTAssertEqual(phase(1440), .arrived)
        XCTAssertEqual(phase(100_000), .arrived)
    }

    func testPhaseBeforeTheStartWaitsForTheFirstRide() {
        XCTAssertEqual(
            TripTiming.plannedPhase(trip: trip(), startedAt: start, now: seconds(-600)),
            .waiting(legIndex: 0)
        )
    }

    func testSingleRideArrivesAfterTheFinalWalk() {
        let trip = trip(legs: [leg(.metro, "1", walk: 60, ride: 300)], finalWalk: 120)

        XCTAssertEqual(TripTiming.plannedArrival(trip: trip, startedAt: start), seconds(480))
        XCTAssertEqual(TripTiming.plannedPhase(trip: trip, startedAt: start, now: seconds(359)), .riding(legIndex: 0))
        XCTAssertEqual(TripTiming.plannedPhase(trip: trip, startedAt: start, now: seconds(360)), .arrived)
    }
}
