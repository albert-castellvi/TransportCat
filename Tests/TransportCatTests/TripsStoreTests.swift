import XCTest
@testable import TransportCat

/// `TripsStore` (spec S4): saved, habitual and recent trips under
/// `savedTrips.v1` and the one active trip under `activeTrip.v1`, with
/// deduplication by signature, the recents and habituals caps, and the stale
/// expiry of a followed trip.
final class TripsStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "TransportCatTripsTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        if let suiteName {
            defaults.removePersistentDomain(forName: suiteName)
        }
        try super.tearDownWithError()
    }

    // MARK: - Builders

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func leg(
        line: String,
        from: String = "Rocafort",
        to: String = "Catalunya",
        ride: Int = 300
    ) -> SavedTripLeg {
        SavedTripLeg(
            operatorKind: .metro,
            lineCode: line,
            lineName: "L\(line)",
            colorHex: "CE1126",
            textColorHex: "FFFFFF",
            headsign: "Fondo",
            fromName: from,
            toName: to,
            fromStationID: "123",
            toStationID: "126",
            fromPosition: GeoPoint(latitude: 41.38, longitude: 2.16),
            toPosition: GeoPoint(latitude: 41.39, longitude: 2.17),
            rideSeconds: ride,
            walkSecondsBefore: 120,
            geometry: []
        )
    }

    /// A trip whose signature is `(line, from, to)`, minute `offset` after
    /// `t0`. It is built as saved, like a planner trip: only the store decides
    /// the stored kind.
    private func trip(
        _ line: String,
        from: String = "Rocafort",
        to: String = "Catalunya",
        minutes offset: Int = 0,
        ride: Int = 300
    ) -> SavedTrip {
        SavedTrip(
            name: "\(from) → \(to)",
            originName: from,
            destinationName: to,
            origin: GeoPoint(latitude: 41.38, longitude: 2.16),
            destination: GeoPoint(latitude: 41.39, longitude: 2.17),
            kind: .saved,
            createdAt: t0.addingTimeInterval(TimeInterval(offset * 60)),
            lastUsedAt: nil,
            legs: [leg(line: line, from: from, to: to, ride: ride)],
            finalWalkSeconds: 60,
            plannedDurationSeconds: 480
        )
    }

    private func minutes(_ value: TimeInterval) -> Date {
        t0.addingTimeInterval(value * 60)
    }

    // MARK: - Saving

    func testSavePersistsAcrossInstances() throws {
        let store = TripsStore(defaults: defaults)
        let saved = store.save(trip("1"), as: .habitual)

        XCTAssertEqual(store.trips, [saved])
        XCTAssertEqual(saved.kind, .habitual)
        XCTAssertNotNil(defaults.data(forKey: "savedTrips.v1"))

        let reopened = TripsStore(defaults: defaults)
        XCTAssertEqual(reopened.trips, [saved])
        XCTAssertEqual(reopened.ordered, [saved])
    }

    func testSaveDedupesBySignatureAndKeepsTheStoredTrip() throws {
        let store = TripsStore(defaults: defaults)
        let original = store.save(trip("1"), as: .saved)
        // The same rides planned again: another id, the same signature.
        let again = store.save(trip("1", minutes: 5), as: .habitual)

        XCTAssertEqual(store.trips.count, 1)
        XCTAssertEqual(again.id, original.id)
        XCTAssertEqual(again.kind, .habitual)
        XCTAssertEqual(again.createdAt, original.createdAt)
    }

    func testSaveNeverDowngradesAHabitualToRecent() throws {
        let store = TripsStore(defaults: defaults)
        store.save(trip("1"), as: .habitual)

        let reopened = store.save(trip("1"), as: .recent)

        XCTAssertEqual(store.trips.count, 1)
        XCTAssertEqual(reopened.kind, .habitual)
    }

    func testSaveNeverDowngradesASavedToRecentButAllowsPromotion() throws {
        let store = TripsStore(defaults: defaults)
        store.save(trip("1"), as: .saved)

        XCTAssertEqual(store.save(trip("1"), as: .recent).kind, .saved)
        XCTAssertEqual(store.save(trip("1"), as: .habitual).kind, .habitual)
    }

    func testRecentsCapDropsTheOldest() throws {
        let store = TripsStore(defaults: defaults)
        for line in 1...6 {
            store.save(trip("\(line)", minutes: line), as: .recent)
        }

        XCTAssertEqual(store.trips.count, TripsStore.recentLimit)
        XCTAssertEqual(Set(store.trips.map { $0.legs[0].lineCode }), Set(["2", "3", "4", "5", "6"]))

        // The cap survives a reload.
        XCTAssertEqual(TripsStore(defaults: defaults).trips.count, TripsStore.recentLimit)
    }

    func testRecentsCapDropsTheLeastRecentlyUsedFirst() throws {
        let store = TripsStore(defaults: defaults)
        for line in 1...5 {
            store.save(trip("\(line)", minutes: line), as: .recent)
        }
        // Use the oldest one, then add one more recent.
        store.start(id: store.trips.first { $0.legs[0].lineCode == "1" }!.id, now: minutes(60))
        store.save(trip("6", minutes: 61), as: .recent)

        let lines = Set(store.trips.map { $0.legs[0].lineCode })
        XCTAssertEqual(lines, Set(["1", "3", "4", "5", "6"]))
    }

    func testHabitualCapDemotesTheOldestToSaved() throws {
        let store = TripsStore(defaults: defaults)
        for line in 1...4 {
            store.save(trip("\(line)", minutes: line), as: .habitual)
        }
        store.save(trip("5", minutes: 5), as: .habitual)

        let habituals = store.trips.filter { $0.kind == .habitual }
        XCTAssertEqual(habituals.count, TripsStore.habitualLimit)
        XCTAssertEqual(Set(habituals.map { $0.legs[0].lineCode }), Set(["2", "3", "4", "5"]))
        let demoted = try XCTUnwrap(store.trips.first { $0.legs[0].lineCode == "1" })
        XCTAssertEqual(demoted.kind, .saved)
    }

    func testHabitualCapKeepsTheMostRecentlyUsed() throws {
        let store = TripsStore(defaults: defaults)
        for line in 1...4 {
            store.save(trip("\(line)", minutes: line), as: .habitual)
        }
        store.start(id: store.trips.first { $0.legs[0].lineCode == "1" }!.id, now: minutes(50))
        store.save(trip("5", minutes: 51), as: .habitual)

        let habitualLines = Set(store.trips.filter { $0.kind == .habitual }.map { $0.legs[0].lineCode })
        XCTAssertEqual(habitualLines, Set(["1", "3", "4", "5"]))
    }

    // MARK: - Ordering

    func testOrderedPutsHabitualThenSavedThenRecent() throws {
        let store = TripsStore(defaults: defaults)
        store.save(trip("1", minutes: 1), as: .recent)
        store.save(trip("2", minutes: 2), as: .saved)
        store.save(trip("3", minutes: 3), as: .habitual)
        store.save(trip("4", minutes: 4), as: .recent)
        store.save(trip("5", minutes: 5), as: .saved)

        XCTAssertEqual(store.ordered.map { $0.legs[0].lineCode }, ["3", "5", "2", "4", "1"])
    }

    func testOrderedUsesLastUseInsideAGroup() throws {
        let store = TripsStore(defaults: defaults)
        let a = store.save(trip("1", from: "A", minutes: 1), as: .saved)
        let b = store.save(trip("2", from: "B", minutes: 2), as: .saved)
        let c = store.save(trip("3", from: "C", minutes: 3), as: .saved)

        XCTAssertEqual(store.ordered.map(\.id), [c.id, b.id, a.id])
        store.start(id: a.id, now: minutes(10))
        XCTAssertEqual(store.ordered.map(\.id), [a.id, c.id, b.id])
    }

    // MARK: - Editing

    func testRemoveRenamesAndSetKind() throws {
        let store = TripsStore(defaults: defaults)
        let a = store.save(trip("1"), as: .saved)
        let b = store.save(trip("2"), as: .saved)

        store.rename(id: a.id, to: "Feina")
        XCTAssertEqual(store.trip(id: a.id)?.name, "Feina")
        store.rename(id: a.id, to: "   ")
        XCTAssertEqual(store.trip(id: a.id)?.name, "Feina")

        store.setKind(id: b.id, .habitual)
        XCTAssertEqual(store.trip(id: b.id)?.kind, .habitual)

        store.remove(id: a.id)
        XCTAssertNil(store.trip(id: a.id))

        let reopened = TripsStore(defaults: defaults)
        XCTAssertNil(reopened.trip(id: a.id))
        XCTAssertEqual(reopened.trip(id: b.id)?.kind, .habitual)
        XCTAssertEqual(reopened.trip(id: b.id)?.name, "Rocafort → Catalunya")
    }

    // MARK: - Following

    func testStartEndsAndPersistsAcrossInstances() throws {
        let store = TripsStore(defaults: defaults)
        let trip = store.save(trip("1"), as: .saved)
        let start = minutes(10)

        store.start(id: trip.id, now: start)

        XCTAssertEqual(store.activeTrip, ActiveTrip(tripID: trip.id, startedAt: start))
        XCTAssertEqual(store.trip(id: trip.id)?.lastUsedAt, start)
        XCTAssertEqual(store.activeSavedTrip?.id, trip.id)

        let reopened = TripsStore(defaults: defaults)
        XCTAssertEqual(reopened.activeSavedTrip?.id, trip.id)
        XCTAssertEqual(reopened.activeTrip?.startedAt, start)

        reopened.endActive()
        XCTAssertNil(reopened.activeSavedTrip)
        XCTAssertNil(TripsStore(defaults: defaults).activeTrip)
    }

    func testStartOfAnUnknownTripSavesItAsRecent() throws {
        let store = TripsStore(defaults: defaults)
        let trip = trip("1")
        let start = minutes(10)

        store.start(trip: trip, now: start)

        XCTAssertEqual(store.trips.map(\.id), [trip.id])
        XCTAssertEqual(store.trips.first?.kind, .recent)
        XCTAssertEqual(store.activeTrip, ActiveTrip(tripID: trip.id, startedAt: start))
        XCTAssertEqual(store.trips.first?.lastUsedAt, start)
    }

    func testStartOfAKnownTripKeepsItsKind() throws {
        let store = TripsStore(defaults: defaults)
        let habitual = store.save(trip("1"), as: .habitual)

        store.start(trip: trip("1"), now: minutes(10))

        XCTAssertEqual(store.trips.count, 1)
        XCTAssertEqual(store.trip(id: habitual.id)?.kind, .habitual)
    }

    func testRemovingTheActiveTripEndsIt() throws {
        let store = TripsStore(defaults: defaults)
        let trip = store.save(trip("1"), as: .saved)
        store.start(id: trip.id, now: minutes(10))

        store.remove(id: trip.id)

        XCTAssertNil(store.activeTrip)
        XCTAssertNil(store.activeSavedTrip)
    }

    // MARK: - Expiry

    func testStaleActiveTripExpiresWhenReloaded() throws {
        // One ride of 300 s plus a 60 s walk: a 6-minute plan.
        let store = TripsStore(defaults: defaults)
        let saved = store.save(trip("1"), as: .saved)

        func reopenStarted(at startedAt: Date) throws -> TripsStore {
            defaults.set(
                try JSONEncoder().encode(ActiveTrip(tripID: saved.id, startedAt: startedAt)),
                forKey: "activeTrip.v1"
            )
            return TripsStore(defaults: defaults)
        }

        // 8 min planned (2 walk + 5 ride + 1 walk) + the grace, 5 s before the edge
        // (the store reads its own clock a few ms later): followed.
        let edge = Date()
        XCTAssertNotNil(
            try reopenStarted(at: edge.addingTimeInterval(-(480 + TripsStore.staleGrace - 5))).activeSavedTrip
        )

        // One second past the grace: ended, and the end is written back.
        let stale = Date()
        let reopened = try reopenStarted(at: stale.addingTimeInterval(-(480 + TripsStore.staleGrace + 1)))
        XCTAssertNil(reopened.activeTrip)
        XCTAssertNil(reopened.activeSavedTrip)
        XCTAssertNil(TripsStore(defaults: defaults).activeTrip)
    }

    func testExpireIfStaleKeepsAFreshTrip() throws {
        let trip = trip("1")
        let store = TripsStore(defaults: defaults)
        store.start(trip: trip, now: t0)

        store.expireIfStale(now: t0.addingTimeInterval(480 + TripsStore.staleGrace))

        XCTAssertEqual(store.activeSavedTrip?.id, trip.id)
    }

    func testExpireIfStaleEndsAPastArrival() throws {
        let trip = trip("1")
        let store = TripsStore(defaults: defaults)
        store.start(trip: trip, now: t0)

        store.expireIfStale(now: t0.addingTimeInterval(480 + TripsStore.staleGrace + 1))

        XCTAssertNil(store.activeTrip)
    }

    // MARK: - Tolerant decode

    func testGarbageDataReadsAsEmpty() throws {
        defaults.set(Data("not json".utf8), forKey: "savedTrips.v1")
        defaults.set(Data("not json".utf8), forKey: "activeTrip.v1")

        let store = TripsStore(defaults: defaults)

        XCTAssertTrue(store.trips.isEmpty)
        XCTAssertNil(store.activeTrip)
        XCTAssertTrue(store.ordered.isEmpty)
    }
}
