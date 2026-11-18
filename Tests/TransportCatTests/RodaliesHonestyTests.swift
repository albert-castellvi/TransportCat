import XCTest
@testable import TransportCat

/// Tests for the honesty rules of the Rodalies map (review A.7 level 1): the
/// client-side position age, the grouping of co-located trains, the short
/// transition after a stop reassignment and the sanity of far-away points.
///
/// Every type under test takes its clock as a parameter, so the tests run at a
/// fixed date and never depend on the wall clock.
final class RodaliesPositionTrackingTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let here = GeoPoint(latitude: 41.38, longitude: 2.18)

    /// A point due north of `base` by `meters`, in the same equirectangular
    /// approximation the app measures distances with.
    private func north(of base: GeoPoint, by meters: Double) -> GeoPoint {
        GeoPoint(
            latitude: base.latitude + meters / GeoMath.earthRadiusMeters * 180 / .pi,
            longitude: base.longitude
        )
    }

    func testPositionAgeAdvancesOnlyWhenThePositionChanges() throws {
        var tracking = RodaliesPositionTracking()
        XCTAssertTrue(
            tracking.update(trainID: "1", position: here, projectedDistance: 1_000, now: start)
        )
        XCTAssertEqual(
            try XCTUnwrap(tracking.age(for: "1", now: start.addingTimeInterval(120))),
            120,
            accuracy: 1e-9
        )

        // The feed republishes the same stop coordinate: the position has not
        // changed, so the age keeps counting from the first sighting.
        XCTAssertFalse(
            tracking.update(trainID: "1", position: here, projectedDistance: 1_000, now: start.addingTimeInterval(120))
        )
        XCTAssertEqual(
            try XCTUnwrap(tracking.age(for: "1", now: start.addingTimeInterval(121))),
            121,
            accuracy: 1e-9
        )

        // 10 m is jitter, below the 25 m threshold.
        XCTAssertFalse(
            tracking.update(
                trainID: "1",
                position: north(of: here, by: 10),
                projectedDistance: 1_000,
                now: start.addingTimeInterval(130)
            )
        )
        XCTAssertEqual(
            try XCTUnwrap(tracking.age(for: "1", now: start.addingTimeInterval(131))),
            131,
            accuracy: 1e-9
        )

        // 40 m is a real move: the age resets.
        XCTAssertTrue(
            tracking.update(
                trainID: "1",
                position: north(of: here, by: 40),
                projectedDistance: 1_040,
                now: start.addingTimeInterval(140)
            )
        )
        XCTAssertEqual(
            try XCTUnwrap(tracking.age(for: "1", now: start.addingTimeInterval(140))),
            0,
            accuracy: 1e-9
        )
    }

    func testProjectedDistanceChangeCountsAtTheSamePoint() throws {
        var tracking = RodaliesPositionTracking()
        XCTAssertTrue(
            tracking.update(trainID: "1", position: here, projectedDistance: 1_000, now: start)
        )
        // Same coordinate, but the train projected to a different stop: the map
        // draws it elsewhere, so it must count as a change.
        XCTAssertTrue(
            tracking.update(
                trainID: "1",
                position: here,
                projectedDistance: 1_100,
                now: start.addingTimeInterval(30)
            )
        )
        XCTAssertEqual(
            try XCTUnwrap(tracking.age(for: "1", now: start.addingTimeInterval(30))),
            0,
            accuracy: 1e-9
        )
    }

    func testPruneForgetsTrainsNoLongerInTheFeed() {
        var tracking = RodaliesPositionTracking()
        tracking.update(trainID: "1", position: here, projectedDistance: 0, now: start)
        tracking.update(trainID: "2", position: here, projectedDistance: 0, now: start)
        tracking.prune(keeping: ["2"])
        XCTAssertNil(tracking.lastChangedAt(for: "1"))
        XCTAssertNotNil(tracking.lastChangedAt(for: "2"))
    }

    func testEstimatedWordingGrowsAnAgeAfterTheFreshnessThreshold() {
        let now = start.addingTimeInterval(300)
        XCTAssertEqual(RodaliesPositionSourceText.estimated(age: nil, now: now), "Posició de Renfe")
        XCTAssertEqual(RodaliesPositionSourceText.estimated(age: 60, now: now), "Posició de Renfe")
        let stale = RodaliesPositionSourceText.estimated(age: 180, now: now)
        XCTAssertTrue(stale.contains("sense canvi"))
        XCTAssertTrue(stale.contains("fa 3 min"))
    }

    /// A position interpolated between two stops names both sources, so the
    /// rider is not told it is a live fix.
    func testInterpolatedWordingNamesTheTimetableAndTheEta() {
        XCTAssertEqual(
            RodaliesPositionSourceText.interpolated,
            "Posició estimada amb l'horari i l'ETA de Renfe"
        )
    }

    /// A snapped point is an interpolation of the track, whatever the status.
    func testSnappedPositionsAreEstimates() {
        XCTAssertTrue(
            RodaliesPositionEstimate.isEstimated(status: "IN_TRANSIT_TO", isSnapped: true)
        )
        XCTAssertTrue(RodaliesPositionEstimate.isEstimated(status: nil, isSnapped: true))
    }

    /// A raw `INCOMING_AT` or `STOPPED_AT` point is the stop's coordinate, not
    /// a fix; only a raw `IN_TRANSIT_TO` point is the feed's own point.
    func testRawStopCoordinatesAreEstimates() {
        XCTAssertTrue(
            RodaliesPositionEstimate.isEstimated(status: "INCOMING_AT", isSnapped: false)
        )
        XCTAssertTrue(
            RodaliesPositionEstimate.isEstimated(status: "STOPPED_AT", isSnapped: false)
        )
        XCTAssertFalse(
            RodaliesPositionEstimate.isEstimated(status: "IN_TRANSIT_TO", isSnapped: false)
        )
    }
}

final class RodaliesVehicleGroupingTests: XCTestCase {
    private let hospitalet = GeoPoint(latitude: 41.36431, longitude: 2.100894)

    private func vehicle(_ id: String, at point: GeoPoint) -> MapVehicle {
        MapVehicle(
            id: "rodalies-\(id)",
            lineCode: "R1",
            colorHex: "7DBCEC",
            position: point,
            heading: 0,
            label: "L'Hospitalet de Llobregat"
        )
    }

    func testElevenCoLocatedVehiclesBecomeOneMarkerWithCount() {
        let vehicles = (0..<11).map { vehicle("\($0)", at: hospitalet) }
        let groups = RodaliesVehicleGrouping.groups(vehicles)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.count, 11)
        XCTAssertEqual(groups.first?.members.count, 11)
        // The lowest id represents the group, so the marker is stable across polls.
        XCTAssertEqual(groups.first?.representative.id, "rodalies-0")
    }

    func testVehiclesThirtyMetresApartStaySeparate() {
        let north = GeoPoint(
            latitude: hospitalet.latitude + 30.4 / GeoMath.earthRadiusMeters * 180 / .pi,
            longitude: hospitalet.longitude
        )
        let first = vehicle("a", at: hospitalet)
        let second = vehicle("b", at: north)
        XCTAssertGreaterThanOrEqual(
            GeoMath.distanceMeters(from: first.position, to: second.position),
            RodaliesVehicleGrouping.radiusMeters
        )
        XCTAssertEqual(RodaliesVehicleGrouping.groups([first, second]).count, 2)
    }

    func testVehiclesWithinTheRadiusShareAMarker() {
        let north = GeoPoint(
            latitude: hospitalet.latitude + 12 / GeoMath.earthRadiusMeters * 180 / .pi,
            longitude: hospitalet.longitude
        )
        let groups = RodaliesVehicleGrouping.groups([
            vehicle("a", at: hospitalet),
            vehicle("b", at: north),
        ])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.count, 2)
    }
}

final class RodaliesMotionTransitionTests: XCTestCase {
    func testLargeReassociationJumpIsNotGlidedOverAFullPoll() {
        let poll: TimeInterval = 30
        // A small real move keeps the full glide.
        XCTAssertEqual(
            RodaliesMotionTransition.duration(forJumpMeters: 50, pollDuration: poll),
            poll
        )
        // The 1.8 km / 5.6 km stop reassignments of the review get the short
        // transition instead of a 30 s flight at hundreds of km/h.
        XCTAssertEqual(
            RodaliesMotionTransition.duration(forJumpMeters: 1_864, pollDuration: poll),
            RodaliesMotionTransition.shortTransitionSeconds
        )
        XCTAssertEqual(
            RodaliesMotionTransition.duration(forJumpMeters: -5_600, pollDuration: poll),
            RodaliesMotionTransition.shortTransitionSeconds
        )
        XCTAssertEqual(RodaliesMotionTransition.shortTransitionSeconds, 0.4)
        XCTAssertEqual(
            RodaliesMotionTransition.reassignmentThresholdMeters,
            FGCNetwork.maxSnapOffsetMeters
        )
    }
}

final class RodaliesPositionSanityTests: XCTestCase {
    /// A short northbound track around Barcelona.
    private var geometry: FGCLineGeometry {
        let points = [
            GeoPoint(latitude: 41.38, longitude: 2.16),
            GeoPoint(latitude: 41.40, longitude: 2.18),
        ]
        return FGCLineGeometry(
            polylines: [points],
            cumulative: [[0, GeoMath.distanceMeters(from: points[0], to: points[1])]]
        )
    }

    func testPointBeyondTheFiveKilometreLimitIsHidden() throws {
        // The R4 77552 record of the review: a stop of Arc de Triomf with the
        // coordinates of Planoles, about 100 km away.
        let far = GeoPoint(latitude: 42.314304, longitude: 2.0996497)
        let projection = try XCTUnwrap(
            RodaliesPositionSanity.nearestProjection(of: far, in: geometry)
        )
        XCTAssertGreaterThan(
            projection.offsetMeters,
            RodaliesPositionSanity.maximumDistanceFromLineMeters
        )
        XCTAssertEqual(
            RodaliesPositionSanity.placement(offsetMeters: projection.offsetMeters),
            .hidden
        )
    }

    func testPointOnTheTrackIsSnapped() throws {
        let on = GeoPoint(latitude: 41.39, longitude: 2.17)
        let projection = try XCTUnwrap(
            RodaliesPositionSanity.nearestProjection(of: on, in: geometry)
        )
        XCTAssertLessThan(projection.offsetMeters, 10)
        XCTAssertEqual(
            RodaliesPositionSanity.placement(offsetMeters: projection.offsetMeters),
            .snapped
        )
    }

    func testPointNearButNotOnTheTrackIsDrawnRaw() {
        // Closer than the 5 km sanity limit, farther than the 300 m snap.
        XCTAssertEqual(RodaliesPositionSanity.placement(offsetMeters: 1_000), .raw)
        // No track known: the map cannot judge the point and draws it raw.
        XCTAssertEqual(RodaliesPositionSanity.placement(offsetMeters: nil), .raw)
        // Exactly on the limit is still a record of the line; past it is not.
        XCTAssertEqual(RodaliesPositionSanity.placement(offsetMeters: 5_000), .raw)
        XCTAssertEqual(RodaliesPositionSanity.placement(offsetMeters: 5_001), .hidden)
    }
}
