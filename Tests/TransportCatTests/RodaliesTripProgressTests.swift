import XCTest
@testable import TransportCat

/// Tests for the pure interpolation of a live train between two stops.
///
/// The legs are the review's real cases: 25661 R1 from Sant Adrià de Besòs
/// (79403) to Badalona (79404), and 77550 R4 from Cornellà (72303) to Sant Joan
/// Despí (72302). Distances are synthetic but proportional (about 1.9 km on
/// R1); the timetable times are synthetic and the clock is always a parameter,
/// so every expectation is exact.
final class RodaliesTripProgressTests: XCTestCase {
    /// 2026-11-18 17:12:22 UTC, the base of the review's vehicle samples.
    private let base = Date(timeIntervalSince1970: 1_795_021_942)

    private func leg(
        fromStopID: String = "79403",
        fromDistance: Double = 1_000,
        toStopID: String = "79404",
        toDistance: Double = 2_900,
        scheduledDeparture: Date? = nil,
        scheduledDuration: TimeInterval? = nil,
        predictedArrival: Date? = nil,
        isStoppedAtStation: Bool = false
    ) -> RodaliesTripLeg {
        RodaliesTripLeg(
            fromStopID: fromStopID,
            fromDistance: fromDistance,
            toStopID: toStopID,
            toDistance: toDistance,
            scheduledDeparture: scheduledDeparture,
            scheduledDuration: scheduledDuration,
            predictedArrival: predictedArrival,
            isStoppedAtStation: isStoppedAtStation
        )
    }

    // MARK: - ETA interpolation

    /// With a ten-minute timetabled run and a matched ETA, half the wall time
    /// puts the train halfway along the leg, which is the whole point of the
    /// estimate: the map moves between stops without a GPS fix.
    func testProgressIsHalfwayAtHalfTheTimetabledRun() {
        let outcome = RodaliesTripProgress.estimate(
            for: leg(
                scheduledDeparture: base,
                scheduledDuration: 540,
                predictedArrival: base.addingTimeInterval(600)
            ),
            now: base.addingTimeInterval(300)
        )

        XCTAssertEqual(outcome.progress, 0.5, accuracy: 1e-12)
        XCTAssertEqual(outcome.distanceAlong, 1_950, accuracy: 1e-9)
        XCTAssertEqual(outcome.estimate, .eta)
    }

    /// 25661 R1 has left Sant Adrià and is due at Badalona in ten minutes: at
    /// five minutes the marker sits on the middle of the drawn leg.
    func testR1Train25661ProgressesFromSantAdriaToBadalona() {
        let outcome = RodaliesTripProgress.estimate(
            for: leg(
                fromStopID: "79403",
                fromDistance: 1_000,
                toStopID: "79404",
                toDistance: 2_900,
                scheduledDeparture: base,
                predictedArrival: base.addingTimeInterval(600)
            ),
            now: base.addingTimeInterval(300)
        )

        XCTAssertEqual(outcome.estimate, .eta)
        XCTAssertEqual(outcome.progress, 0.5, accuracy: 1e-12)
        XCTAssertEqual(outcome.distanceAlong, 1_950, accuracy: 1e-9)
    }

    /// Before the departure the fraction is negative: the marker stays on the
    /// origin station instead of backing off the line.
    func testProgressClampsAtTheStation() {
        let outcome = RodaliesTripProgress.estimate(
            for: leg(scheduledDeparture: base, predictedArrival: base.addingTimeInterval(600)),
            now: base.addingTimeInterval(-120)
        )

        XCTAssertEqual(outcome.progress, 0)
        XCTAssertEqual(outcome.distanceAlong, 1_000)
        XCTAssertEqual(outcome.estimate, .eta)
    }

    /// Past a plausible ETA the fraction is above one: the marker stops at the
    /// destination stop and never overshoots it.
    func testProgressClampsAtTheNextStop() {
        let outcome = RodaliesTripProgress.estimate(
            for: leg(scheduledDeparture: base, predictedArrival: base.addingTimeInterval(600)),
            now: base.addingTimeInterval(900)
        )

        XCTAssertEqual(outcome.progress, 1)
        XCTAssertEqual(outcome.distanceAlong, 2_900)
        XCTAssertEqual(outcome.estimate, .eta)
    }

    /// Exactly five minutes in the past is still inside the tolerance (the rule
    /// excludes only predictions older than five minutes).
    func testAnEtaExactlyFiveMinutesInThePastIsStillPlausible() {
        let outcome = RodaliesTripProgress.estimate(
            for: leg(
                scheduledDeparture: base.addingTimeInterval(-1_200),
                predictedArrival: base.addingTimeInterval(-300)
            ),
            now: base
        )

        XCTAssertEqual(outcome.estimate, .eta)
        XCTAssertEqual(outcome.progress, 1)
    }

    /// Exactly one hour ahead is still inside the horizon.
    func testAnEtaExactlyOneHourAheadIsStillPlausible() {
        let outcome = RodaliesTripProgress.estimate(
            for: leg(
                scheduledDeparture: base.addingTimeInterval(-300),
                predictedArrival: base.addingTimeInterval(3_600)
            ),
            now: base
        )

        XCTAssertEqual(outcome.estimate, .eta)
        XCTAssertEqual(outcome.progress, 300.0 / 3_900.0, accuracy: 1e-12)
    }

    // MARK: - STOPPED_AT

    /// A train the feed reports stopped stays on the station marker until its
    /// scheduled departure time, even though the ETA would place it further on.
    func testStoppedTrainStaysAtTheStationUntilItsScheduledDeparture() {
        let outcome = RodaliesTripProgress.estimate(
            for: leg(
                scheduledDeparture: base.addingTimeInterval(60),
                predictedArrival: base.addingTimeInterval(600),
                isStoppedAtStation: true
            ),
            now: base
        )

        XCTAssertEqual(outcome.estimate, .stoppedAtStation)
        XCTAssertEqual(outcome.progress, 0)
        XCTAssertEqual(outcome.distanceAlong, 1_000)
    }

    /// Without a scheduled departure nothing proves the train left the
    /// platform, so a stopped train keeps its station marker.
    func testStoppedTrainWithNoScheduledDepartureStaysPut() {
        let outcome = RodaliesTripProgress.estimate(
            for: leg(predictedArrival: base.addingTimeInterval(600), isStoppedAtStation: true),
            now: base.addingTimeInterval(300)
        )

        XCTAssertEqual(outcome.estimate, .stoppedAtStation)
        XCTAssertEqual(outcome.progress, 0)
        XCTAssertEqual(outcome.distanceAlong, 1_000)
    }

    /// Once the scheduled departure has passed, the same stopped train is
    /// interpolated with its ETA like any other train on the leg.
    func testStoppedTrainLeavesOnceTheScheduledDepartureHasPassed() {
        let outcome = RodaliesTripProgress.estimate(
            for: leg(
                scheduledDeparture: base,
                predictedArrival: base.addingTimeInterval(600),
                isStoppedAtStation: true
            ),
            now: base.addingTimeInterval(300)
        )

        XCTAssertEqual(outcome.estimate, .eta)
        XCTAssertEqual(outcome.progress, 0.5, accuracy: 1e-12)
    }

    /// A stopped train past its departure with no ETA still moves with the
    /// timetabled run instead of freezing on the platform.
    func testStoppedTrainUsesTheScheduleWhenTheEtaIsMissing() {
        let outcome = RodaliesTripProgress.estimate(
            for: leg(
                scheduledDeparture: base,
                scheduledDuration: 600,
                isStoppedAtStation: true
            ),
            now: base.addingTimeInterval(300)
        )

        XCTAssertEqual(outcome.estimate, .scheduled)
        XCTAssertEqual(outcome.progress, 0.5, accuracy: 1e-12)
    }

    // MARK: - Impossible ETAs and fallbacks

    /// An ETA eight minutes in the past is noise: the timetabled leg duration
    /// takes over from the same scheduled departure.
    func testEtaEightMinutesInThePastFallsBackToTheTimetabledRun() {
        let outcome = RodaliesTripProgress.estimate(
            for: leg(
                scheduledDeparture: base.addingTimeInterval(-900),
                scheduledDuration: 1_200,
                predictedArrival: base.addingTimeInterval(-480)
            ),
            now: base
        )

        XCTAssertEqual(outcome.estimate, .scheduled)
        XCTAssertEqual(outcome.progress, 0.75, accuracy: 1e-12)
        XCTAssertEqual(outcome.distanceAlong, 1_000 + 0.75 * 1_900, accuracy: 1e-9)
    }

    /// An ETA ninety minutes ahead belongs to another service, not to a train
    /// already between two stops: the schedule wins.
    func testEtaNinetyMinutesAheadFallsBackToTheTimetabledRun() {
        let outcome = RodaliesTripProgress.estimate(
            for: leg(
                scheduledDeparture: base.addingTimeInterval(-300),
                scheduledDuration: 600,
                predictedArrival: base.addingTimeInterval(5_400)
            ),
            now: base
        )

        XCTAssertEqual(outcome.estimate, .scheduled)
        XCTAssertEqual(outcome.progress, 0.5, accuracy: 1e-12)
    }

    /// An ETA that lands before the train's own departure cannot be used as a
    /// denominator, so the schedule is the fallback.
    func testEtaBeforeItsOwnDepartureFallsBackToTheTimetabledRun() {
        let outcome = RodaliesTripProgress.estimate(
            for: leg(
                scheduledDeparture: base.addingTimeInterval(-200),
                scheduledDuration: 600,
                predictedArrival: base.addingTimeInterval(-250)
            ),
            now: base
        )

        XCTAssertEqual(outcome.estimate, .scheduled)
        XCTAssertEqual(outcome.progress, 200.0 / 600.0, accuracy: 1e-12)
    }

    /// Missing ETA is not an error: the pack's leg duration still animates the
    /// train between the stops.
    func testMissingEtaFallsBackToTheScheduledDuration() {
        let outcome = RodaliesTripProgress.estimate(
            for: leg(scheduledDeparture: base, scheduledDuration: 600),
            now: base.addingTimeInterval(300)
        )

        XCTAssertEqual(outcome.estimate, .scheduled)
        XCTAssertEqual(outcome.progress, 0.5, accuracy: 1e-12)
    }

    /// With neither a plausible ETA nor a timetabled duration there is nothing
    /// honest to draw between the stops: the caller keeps the feed's point.
    func testMissingEtaAndDurationDrawsTheReportedPoint() {
        let outcome = RodaliesTripProgress.estimate(
            for: leg(scheduledDeparture: base.addingTimeInterval(-300)),
            now: base
        )

        XCTAssertEqual(outcome.estimate, .none)
        XCTAssertEqual(outcome.progress, 0)
        XCTAssertEqual(outcome.distanceAlong, 1_000)
    }

    /// An out-of-window ETA without a duration to replace it also degrades to
    /// the reported point.
    func testOutOfWindowEtaWithoutDurationDrawsTheReportedPoint() {
        let outcome = RodaliesTripProgress.estimate(
            for: leg(
                scheduledDeparture: base.addingTimeInterval(-300),
                predictedArrival: base.addingTimeInterval(4_000)
            ),
            now: base
        )

        XCTAssertEqual(outcome.estimate, .none)
    }

    // MARK: - Direction order

    /// A leg whose destination is not further along the train's own direction
    /// is not interpolated backwards: the distances and the direction geometry
    /// must agree.
    func testLegThatDoesNotAdvanceAlongTheDirectionIsRejected() {
        let outcome = RodaliesTripProgress.estimate(
            for: leg(
                fromStopID: "72303",
                fromDistance: 5_000,
                toStopID: "72302",
                toDistance: 3_500,
                scheduledDeparture: base,
                predictedArrival: base.addingTimeInterval(600)
            ),
            now: base.addingTimeInterval(300)
        )

        XCTAssertEqual(outcome.estimate, .none)
        XCTAssertEqual(outcome.distanceAlong, 5_000)
    }

    /// The same R4 pair, ordered as the direction polyline stores it, does
    /// interpolate: 77550 from Cornellà to Sant Joan Despí.
    func testR4LegInDirectionOrderIsInterpolated() {
        let outcome = RodaliesTripProgress.estimate(
            for: leg(
                fromStopID: "72303",
                fromDistance: 3_500,
                toStopID: "72302",
                toDistance: 5_000,
                scheduledDeparture: base,
                predictedArrival: base.addingTimeInterval(600)
            ),
            now: base.addingTimeInterval(300)
        )

        XCTAssertEqual(outcome.estimate, .eta)
        XCTAssertEqual(outcome.progress, 0.5, accuracy: 1e-12)
        XCTAssertEqual(outcome.distanceAlong, 4_250, accuracy: 1e-9)
    }

    // MARK: - Feed point preference

    /// A feed point more than a kilometre from the estimate is the safer truth
    /// and must win; a nearby one is not enough to abandon the interpolation.
    func testFeedPointWinsBeyondOneKilometreAndLosesWithinIt() {
        // A straight east-west track at latitude 41: ~1.68 km long.
        let points = [GeoPoint(latitude: 41.0, longitude: 2.0), GeoPoint(latitude: 41.0, longitude: 2.02)]
        let cumulative = GeoMath.cumulativeDistances(of: points)
        let halfway = cumulative[1] / 2

        let nearby = GeoPoint(latitude: 41.0, longitude: 2.005) // ~420 m from the estimate
        let faraway = GeoPoint(latitude: 41.0, longitude: 2.04) // ~2.5 km from the estimate

        XCTAssertFalse(
            RodaliesTripProgress.prefersFeedPoint(
                feedPoint: nearby,
                interpolatedDistance: halfway,
                points: points,
                cumulative: cumulative
            )
        )
        XCTAssertTrue(
            RodaliesTripProgress.prefersFeedPoint(
                feedPoint: faraway,
                interpolatedDistance: halfway,
                points: points,
                cumulative: cumulative
            )
        )
    }

    /// With no geometry to interpolate on there is no estimate to compare with,
    /// so the feed point is the only thing left and is preferred.
    func testFeedPointWinsWhenThereIsNoGeometry() {
        XCTAssertTrue(
            RodaliesTripProgress.prefersFeedPoint(
                feedPoint: GeoPoint(latitude: 41.0, longitude: 2.0),
                interpolatedDistance: 500,
                points: [],
                cumulative: []
            )
        )
    }
}
