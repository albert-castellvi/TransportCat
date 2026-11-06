import XCTest
@testable import TransportCat

/// Tests for the pure follow-session rules (S5–S8): plan building, strip
/// roles, announcements, countdown text and the alight alarm date.
final class FollowSessionTests: XCTestCase {
    // MARK: Helpers

    private func stop(_ code: String, name: String, eta: Int? = nil, interchanges: [String] = [], facility: String? = nil) -> FollowStop {
        FollowStop(code: code, name: name, etaSeconds: eta, interchanges: interchanges, facilityNote: facility)
    }

    private let vehicle = FollowVehicle(
        mode: .metro,
        vehicleID: "train-1",
        lineDisplayName: "L2",
        lineColorHex: "007AB8",
        terminusName: "Paral·lel",
        isEstimated: false
    )

    // MARK: plan

    func testNextIsTheFirstUpcomingStop() {
        let snapshot = FollowSnapshot(
            upcoming: [stop("B", name: "B"), stop("C", name: "C")],
            passed: [stop("A", name: "A")]
        )
        let plan = FollowSession.plan(vehicle: vehicle, snapshot: snapshot, alightStopCode: nil)
        XCTAssertEqual(plan.next?.code, "B")
    }

    func testStripHoldsPassedNextAndAheadCappedAtFive() {
        let snapshot = FollowSnapshot(
            upcoming: [
                stop("B", name: "B"), stop("C", name: "C"), stop("D", name: "D"),
                stop("E", name: "E"), stop("F", name: "F"), stop("G", name: "G"),
            ],
            passed: [stop("X", name: "X"), stop("A", name: "A")]
        )
        let plan = FollowSession.plan(vehicle: vehicle, snapshot: snapshot, alightStopCode: nil)
        XCTAssertEqual(plan.strip.map(\.stop.code), ["A", "B", "C", "D", "E"])
        XCTAssertEqual(plan.strip.map(\.role), [.passed, .next, .ahead, .ahead, .ahead])
    }

    func testStripWithoutPassedStopsStartsAtTheNextStop() {
        let snapshot = FollowSnapshot(upcoming: [stop("B", name: "B"), stop("C", name: "C")], passed: [])
        let plan = FollowSession.plan(vehicle: vehicle, snapshot: snapshot, alightStopCode: nil)
        XCTAssertEqual(plan.strip.map(\.stop.code), ["B", "C"])
        XCTAssertEqual(plan.strip.map(\.role), [.next, .ahead])
    }

    func testAlightCellGetsTheAlightRole() {
        let snapshot = FollowSnapshot(
            upcoming: [stop("B", name: "B"), stop("C", name: "C"), stop("D", name: "D")],
            passed: [stop("A", name: "A")]
        )
        let plan = FollowSession.plan(vehicle: vehicle, snapshot: snapshot, alightStopCode: "C")
        XCTAssertEqual(plan.strip.map(\.role), [.passed, .next, .alight])
    }

    func testAlightRoleOverridesTheNextRoleWhenTheAlightStopIsNext() {
        let snapshot = FollowSnapshot(upcoming: [stop("B", name: "B"), stop("C", name: "C")], passed: [])
        let plan = FollowSession.plan(vehicle: vehicle, snapshot: snapshot, alightStopCode: "B")
        XCTAssertEqual(plan.strip.map(\.role), [.alight, .ahead])
    }

    func testMapLabelsAreTheFirstFourUpcomingStops() {
        let snapshot = FollowSnapshot(
            upcoming: [
                stop("B", name: "B"), stop("C", name: "C"), stop("D", name: "D"),
                stop("E", name: "E"), stop("F", name: "F"),
            ],
            passed: []
        )
        let plan = FollowSession.plan(vehicle: vehicle, snapshot: snapshot, alightStopCode: nil)
        XCTAssertEqual(plan.mapLabels.map(\.code), ["B", "C", "D", "E"])
    }

    func testMapLabelsShowEveryStopWhenFewerThanFour() {
        let snapshot = FollowSnapshot(upcoming: [stop("B", name: "B"), stop("C", name: "C")], passed: [])
        let plan = FollowSession.plan(vehicle: vehicle, snapshot: snapshot, alightStopCode: nil)
        XCTAssertEqual(plan.mapLabels.map(\.code), ["B", "C"])
    }

    func testAlightResolvesOnlyWhenTheCodeIsAhead() {
        let snapshot = FollowSnapshot(upcoming: [stop("B", name: "B")], passed: [stop("A", name: "A")])
        let behind = FollowSession.plan(vehicle: vehicle, snapshot: snapshot, alightStopCode: "A")
        XCTAssertNil(behind.alight)
        XCTAssertNil(behind.progressToAlight)

        let unknown = FollowSession.plan(vehicle: vehicle, snapshot: snapshot, alightStopCode: "ZZ")
        XCTAssertNil(unknown.alight)

        let ahead = FollowSession.plan(vehicle: vehicle, snapshot: snapshot, alightStopCode: "B")
        XCTAssertEqual(ahead.alight?.code, "B")
    }

    func testAlarmStopIsTheUpcomingStopJustBeforeAlight() {
        let snapshot = FollowSnapshot(
            upcoming: [stop("B", name: "B"), stop("C", name: "C"), stop("D", name: "D")],
            passed: []
        )
        XCTAssertEqual(FollowSession.plan(vehicle: vehicle, snapshot: snapshot, alightStopCode: "C").alarmStop?.code, "B")
        XCTAssertEqual(FollowSession.plan(vehicle: vehicle, snapshot: snapshot, alightStopCode: "D").alarmStop?.code, "C")
    }

    func testAlarmStopIsNilWithoutAlightOrWhenAlightIsNext() {
        let snapshot = FollowSnapshot(upcoming: [stop("B", name: "B")], passed: [])
        XCTAssertNil(FollowSession.plan(vehicle: vehicle, snapshot: snapshot, alightStopCode: nil).alarmStop)
        XCTAssertNil(FollowSession.plan(vehicle: vehicle, snapshot: snapshot, alightStopCode: "B").alarmStop)
    }

    func testProgressToAlightFormula() {
        // p = passed.count, a = the alight stop's index in upcoming:
        // p / (p + a + 1). One passed stop, alight at index 2: 1 / 4.
        let snapshot = FollowSnapshot(
            upcoming: [stop("B", name: "B"), stop("C", name: "C"), stop("D", name: "D")],
            passed: [stop("A", name: "A")]
        )
        let plan = FollowSession.plan(vehicle: vehicle, snapshot: snapshot, alightStopCode: "D")
        XCTAssertEqual(plan.progressToAlight ?? -1, 1.0 / 4.0, accuracy: 0.0001)
    }

    func testProgressToAlightBoundsAndNilWithoutAlight() {
        let noPassed = FollowSnapshot(
            upcoming: [stop("B", name: "B"), stop("C", name: "C")],
            passed: []
        )
        // p = 0, a = 1: 0 / 2 = 0.
        XCTAssertEqual(FollowSession.plan(vehicle: vehicle, snapshot: noPassed, alightStopCode: "C").progressToAlight ?? -1, 0, accuracy: 0.0001)

        let manyPassed = FollowSnapshot(
            upcoming: [stop("B", name: "B")],
            passed: [stop("A", name: "A"), stop("Z", name: "Z"), stop("Y", name: "Y")]
        )
        // p = 3, a = 0: 3 / 4 = 0.75.
        XCTAssertEqual(FollowSession.plan(vehicle: vehicle, snapshot: manyPassed, alightStopCode: "B").progressToAlight ?? -1, 0.75, accuracy: 0.0001)

        XCTAssertNil(FollowSession.plan(vehicle: vehicle, snapshot: noPassed, alightStopCode: nil).progressToAlight)
    }

    // MARK: event

    private func eventPlan(next: FollowStop?, alight: FollowStop?) -> FollowPlan {
        FollowPlan(
            vehicle: vehicle,
            next: next,
            upcoming: next.map { [$0] } ?? [],
            strip: [],
            mapLabels: [],
            alight: alight,
            alarmStop: nil,
            progressToAlight: nil
        )
    }

    func testEventIsNilWithoutNextOrWhenNextDidNotChange() {
        let plain = eventPlan(next: stop("B", name: "B"), alight: nil)
        XCTAssertNil(FollowSession.event(previousNextCode: "B", plan: plain))
        XCTAssertNil(FollowSession.event(previousNextCode: nil, plan: eventPlan(next: nil, alight: nil)))
    }

    func testEventAnnouncesOnNextStopChange() {
        let plan = eventPlan(next: stop("B", name: "B"), alight: stop("C", name: "C"))
        XCTAssertEqual(FollowSession.event(previousNextCode: "A", plan: plan), .announce(stop("B", name: "B")))
        // A nil previous code (the start of the session) also announces.
        XCTAssertEqual(FollowSession.event(previousNextCode: nil, plan: plan), .announce(stop("B", name: "B")))
    }

    func testEventAlightsWhenNextIsTheAlightStop() {
        let alight = stop("C", name: "C")
        let plan = eventPlan(next: alight, alight: alight)
        XCTAssertEqual(FollowSession.event(previousNextCode: "B", plan: plan), .alight(alight))
    }

    func testEventIsNilWhenPlanComesFromAnEmptyUpcomingList() {
        let snapshot = FollowSnapshot(upcoming: [], passed: [stop("A", name: "A")])
        let plan = FollowSession.plan(vehicle: vehicle, snapshot: snapshot, alightStopCode: nil)
        XCTAssertNil(FollowSession.event(previousNextCode: nil, plan: plan))
    }

    // MARK: announcementText

    func testAnnounceTextWithoutExtras() {
        let event = FollowEvent.announce(stop("B", name: "Verdaguer"))
        XCTAssertEqual(FollowSession.announcementText(for: event), "Pròxima parada: Verdaguer.")
    }

    func testAnnounceInterchangeForms() {
        XCTAssertEqual(
            FollowSession.announcementText(for: .announce(stop("B", name: "X", interchanges: ["L4"]))),
            "Pròxima parada: X. Correspondència amb la L4."
        )
        XCTAssertEqual(
            FollowSession.announcementText(for: .announce(stop("B", name: "X", interchanges: ["L1", "L4"]))),
            "Pròxima parada: X. Correspondència amb la L1 i la L4."
        )
        XCTAssertEqual(
            FollowSession.announcementText(for: .announce(stop("B", name: "X", interchanges: ["L1", "L3", "L4"]))),
            "Pròxima parada: X. Correspondència amb la L1, la L3 i la L4."
        )
    }

    func testAnnounceWithFacilityNote() {
        XCTAssertEqual(
            FollowSession.announcementText(for: .announce(stop("B", name: "X", facility: "Ascensor fora de servei"))),
            "Pròxima parada: X. Ascensor fora de servei."
        )
    }

    func testAnnounceWithInterchangeAndFacility() {
        XCTAssertEqual(
            FollowSession.announcementText(for: .announce(stop("B", name: "X", interchanges: ["L4"], facility: "Ascensor fora de servei"))),
            "Pròxima parada: X. Correspondència amb la L4. Ascensor fora de servei."
        )
    }

    func testAlightTextAndItsInterchange() {
        XCTAssertEqual(
            FollowSession.announcementText(for: .alight(stop("C", name: "La Pau"))),
            "Baixa a la pròxima: La Pau."
        )
        XCTAssertEqual(
            FollowSession.announcementText(for: .alight(stop("C", name: "La Pau", interchanges: ["L1", "L4"]))),
            "Baixa a la pròxima: La Pau. Correspondència amb la L1 i la L4."
        )
    }

    func testAlightTextHasNoFacilityNote() {
        XCTAssertEqual(
            FollowSession.announcementText(for: .alight(stop("C", name: "La Pau", facility: "Ascensor fora de servei"))),
            "Baixa a la pròxima: La Pau."
        )
    }

    // MARK: etaText

    func testEtaTextNilWithoutEta() {
        XCTAssertNil(FollowSession.etaText(for: stop("B", name: "B")))
    }

    func testEtaTextAraAtOrUnderSixtySeconds() {
        XCTAssertEqual(FollowSession.etaText(for: stop("B", name: "B", eta: 60)), "ara")
        XCTAssertEqual(FollowSession.etaText(for: stop("B", name: "B", eta: 1)), "ara")
    }

    func testEtaTextUsesCountdownTextAboveSixtySeconds() {
        // Arrival.countdownText truncates whole minutes.
        // 61 s is one whole minute ("<1 min" is only for under 60 s).
        XCTAssertEqual(FollowSession.etaText(for: stop("B", name: "B", eta: 61)), "1 min")
        XCTAssertEqual(FollowSession.etaText(for: stop("B", name: "B", eta: 300)), "5 min")
        XCTAssertEqual(FollowSession.etaText(for: stop("B", name: "B", eta: 125)), "2 min")
    }

    // MARK: alightAlarmDate

    func testAlightAlarmDateIsNowPlusTheAlarmStopEta() {
        let snapshot = FollowSnapshot(
            upcoming: [stop("B", name: "B", eta: 40), stop("C", name: "C", eta: 120)],
            passed: []
        )
        let plan = FollowSession.plan(vehicle: vehicle, snapshot: snapshot, alightStopCode: "C")
        let now = Date(timeIntervalSince1970: 1_000)
        // The alarm stop is B (the one before the alight stop C): now + 40 s.
        XCTAssertEqual(FollowSession.alightAlarmDate(plan: plan, now: now), Date(timeIntervalSince1970: 1_040))
    }

    func testAlightAlarmDateNilWithoutAlarmStopOrEta() {
        // No alight stop: no alarm.
        let plain = FollowSnapshot(upcoming: [stop("B", name: "B", eta: 40)], passed: [])
        XCTAssertNil(FollowSession.alightAlarmDate(plan: FollowSession.plan(vehicle: vehicle, snapshot: plain, alightStopCode: nil), now: Date()))

        // The alight stop is the next one: no alarm stop.
        let alightIsNext = FollowSnapshot(upcoming: [stop("B", name: "B", eta: 40)], passed: [])
        XCTAssertNil(FollowSession.alightAlarmDate(plan: FollowSession.plan(vehicle: vehicle, snapshot: alightIsNext, alightStopCode: "B"), now: Date()))

        // The alarm stop (B, before the alight stop C) has no ETA (FGC, D1).
        let noEta = FollowSnapshot(upcoming: [stop("B", name: "B"), stop("C", name: "C", eta: 120)], passed: [])
        XCTAssertNil(FollowSession.alightAlarmDate(plan: FollowSession.plan(vehicle: vehicle, snapshot: noEta, alightStopCode: "C"), now: Date()))
    }
}
