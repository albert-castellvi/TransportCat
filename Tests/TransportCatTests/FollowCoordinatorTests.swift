import XCTest
@testable import TransportCat

/// Tests for `FollowCoordinator` behaviour (S6–S10) with every side-effecting
/// service recorded, so no speech, notification or Live Activity runs.
@MainActor
final class FollowCoordinatorTests: XCTestCase {
    // MARK: Recordings

    private final class Recorder {
        var activityStarts: [FollowPlan] = []
        var activityUpdates: [FollowPlan] = []
        var activityEnds = 0
        var schedulerReschedules: [(date: Date?, stopName: String, line: String)] = []
        var schedulerCancels = 0
        var speech: [String] = []
        var announcerStops = 0
    }

    /// Every coordinator gets its own empty defaults unless a test shares one:
    /// the voice toggle never leaks between tests or into the real app.
    private func makeCoordinator(_ recorder: Recorder, defaults: UserDefaults? = nil) -> FollowCoordinator {
        FollowCoordinator(
            defaults: defaults ?? Self.isolatedDefaults(),
            activityStart: { recorder.activityStarts.append($0) },
            activityUpdate: { recorder.activityUpdates.append($0) },
            activityEnd: { recorder.activityEnds += 1 },
            schedulerReschedule: { recorder.schedulerReschedules.append(($0, $1, $2)) },
            schedulerCancel: { recorder.schedulerCancels += 1 },
            announcerSpeak: { recorder.speech.append($0) },
            announcerStop: { recorder.announcerStops += 1 }
        )
    }

    private func stop(_ code: String, name: String, eta: Int? = nil) -> FollowStop {
        FollowStop(code: code, name: name, etaSeconds: eta, interchanges: [], facilityNote: nil)
    }

    private func vehicle(id: String = "train-1") -> FollowVehicle {
        FollowVehicle(
            mode: .metro,
            vehicleID: id,
            lineDisplayName: "L2",
            lineColorHex: "007AB8",
            terminusName: "Paral·lel",
            isEstimated: false
        )
    }

    private func snapshot(upcoming: [String], etas: [Int?]? = nil, passed: [String] = []) -> FollowSnapshot {
        let upcomingStops = upcoming.enumerated().map { index, code -> FollowStop in
            let eta: Int? = (etas?.count ?? 0) > index ? etas?[index] : nil
            return stop(code, name: code, eta: eta)
        }
        return FollowSnapshot(upcoming: upcomingStops, passed: passed.map { stop($0, name: $0) })
    }

    private static func isolatedDefaults() -> UserDefaults {
        let suiteName = "FollowCoordinatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    // MARK: start

    func testStartFollowsWithNoAlightAndNoAnnouncement() {
        let recorder = Recorder()
        let coordinator = makeCoordinator(recorder)
        coordinator.start(vehicle: vehicle(), snapshot: snapshot(upcoming: ["B", "C"]))

        XCTAssertTrue(coordinator.isFollowing)
        XCTAssertEqual(coordinator.followedVehicleID, "train-1")
        XCTAssertEqual(coordinator.plan?.next?.code, "B")
        XCTAssertNil(coordinator.plan?.alight)
        XCTAssertNil(coordinator.activeEvent)
        XCTAssertEqual(recorder.activityStarts.count, 1)
        XCTAssertEqual(recorder.activityStarts.first?.next?.code, "B")
        XCTAssertTrue(recorder.speech.isEmpty, "starting a session must not announce (S6)")
        XCTAssertFalse(coordinator.isCameraPaused)
        XCTAssertTrue(coordinator.is3D)
    }

    func testStartReplacesARunningSession() {
        let recorder = Recorder()
        let coordinator = makeCoordinator(recorder)
        coordinator.start(vehicle: vehicle(id: "train-1"), snapshot: snapshot(upcoming: ["B"]))
        coordinator.start(vehicle: vehicle(id: "train-2"), snapshot: snapshot(upcoming: ["C"]))

        XCTAssertEqual(coordinator.followedVehicleID, "train-2")
        XCTAssertEqual(recorder.activityEnds, 1, "the replaced session ends first")
        XCTAssertEqual(recorder.activityStarts.count, 2)
        XCTAssertEqual(recorder.schedulerCancels, 1)
        XCTAssertEqual(recorder.announcerStops, 1)
    }

    // MARK: update

    func testUpdateAnnouncesWhenTheNextStopChanges() {
        let recorder = Recorder()
        let coordinator = makeCoordinator(recorder)
        coordinator.start(vehicle: vehicle(), snapshot: snapshot(upcoming: ["B", "C"]))

        coordinator.update(vehicle: vehicle(), snapshot: snapshot(upcoming: ["C"], passed: ["B"]))

        XCTAssertEqual(coordinator.activeEvent, .announce(stop("C", name: "C")))
        XCTAssertEqual(recorder.speech.count, 1)
        XCTAssertEqual(recorder.speech.first, "Pròxima parada: C.")
        XCTAssertEqual(coordinator.plan?.next?.code, "C")
        XCTAssertEqual(recorder.activityUpdates.count, 1)
        XCTAssertEqual(recorder.schedulerCancels, 1, "no alight stop: the alarm stays cancelled")
    }

    func testUpdateAnnouncesEachStopOnlyOnce() {
        let recorder = Recorder()
        let coordinator = makeCoordinator(recorder)
        coordinator.start(vehicle: vehicle(), snapshot: snapshot(upcoming: ["B", "C"]))
        // The 10 Hz feed repeats the same values: no new event, no activity push.
        coordinator.update(vehicle: vehicle(), snapshot: snapshot(upcoming: ["B", "C"]))
        XCTAssertEqual(recorder.activityUpdates.count, 0)
        XCTAssertEqual(recorder.speech.count, 0)
    }

    func testUpdateAlightsOnTheAlightStop() {
        let recorder = Recorder()
        let coordinator = makeCoordinator(recorder)
        coordinator.start(vehicle: vehicle(), snapshot: snapshot(upcoming: ["B", "C"], passed: ["A"]))
        coordinator.setAlightStop(code: "C")

        coordinator.update(vehicle: vehicle(), snapshot: snapshot(upcoming: ["C"], passed: ["B"]))

        XCTAssertEqual(coordinator.activeEvent, .alight(stop("C", name: "C")))
        XCTAssertEqual(recorder.speech.count, 1)
        XCTAssertEqual(recorder.speech.first, "Baixa a la pròxima: C.")
    }

    func testUpdateIsIgnoredForAnotherVehicleAndWhenNotFollowing() {
        let recorder = Recorder()
        let coordinator = makeCoordinator(recorder)

        // Not following yet: nothing happens.
        coordinator.update(vehicle: vehicle(), snapshot: snapshot(upcoming: ["B"]))
        XCTAssertEqual(recorder.activityUpdates.count, 0)

        coordinator.start(vehicle: vehicle(id: "train-1"), snapshot: snapshot(upcoming: ["B"]))
        let before = coordinator.plan
        coordinator.update(vehicle: vehicle(id: "train-2"), snapshot: snapshot(upcoming: ["C"]))
        XCTAssertEqual(coordinator.plan, before, "another vehicle's snapshot must not touch the plan")
        XCTAssertEqual(recorder.activityUpdates.count, 0)
    }

    func testUpdateClearsTheAlightStopOncePassed() {
        let recorder = Recorder()
        let coordinator = makeCoordinator(recorder)
        coordinator.start(vehicle: vehicle(), snapshot: snapshot(upcoming: ["B", "C"], passed: []))
        coordinator.setAlightStop(code: "C")
        XCTAssertEqual(coordinator.plan?.alight?.code, "C")

        coordinator.update(vehicle: vehicle(), snapshot: snapshot(upcoming: ["C"], passed: ["B"]))
        coordinator.update(vehicle: vehicle(), snapshot: snapshot(upcoming: [], passed: ["B", "C"]))

        XCTAssertNil(coordinator.plan?.alight)
        XCTAssertEqual(recorder.schedulerCancels, 1, "passing the alight stop cancels the alarm")
        let reschedulesBefore = recorder.schedulerReschedules.count
        // Repicking the same stop now fails, because it is no longer ahead:
        // no new alarm is scheduled.
        coordinator.setAlightStop(code: "C")
        XCTAssertNil(coordinator.plan?.alight)
        XCTAssertEqual(recorder.schedulerReschedules.count, reschedulesBefore)
    }

    func testUpdateReschedulesTheAlightAlarmForTheStopBefore() {
        let recorder = Recorder()
        let coordinator = makeCoordinator(recorder)
        coordinator.start(vehicle: vehicle(), snapshot: snapshot(upcoming: ["B", "C"], etas: [40, 120]))
        coordinator.setAlightStop(code: "C")

        XCTAssertEqual(recorder.schedulerReschedules.count, 1)
        let reschedule = try! XCTUnwrap(recorder.schedulerReschedules.first)
        XCTAssertEqual(reschedule.stopName, "C")
        XCTAssertEqual(reschedule.line, "L2")
        XCTAssertNotNil(reschedule.date, "the alarm stop has an ETA")
    }

    // MARK: alight picker

    func testSetAlightStopRecomputesAndSchedules() {
        let recorder = Recorder()
        let coordinator = makeCoordinator(recorder)
        coordinator.start(vehicle: vehicle(), snapshot: snapshot(upcoming: ["B", "C"], passed: ["A"]))

        coordinator.setAlightStop(code: "C")

        XCTAssertEqual(coordinator.plan?.alight?.code, "C")
        XCTAssertEqual(coordinator.plan?.alarmStop?.code, "B")
        XCTAssertEqual(coordinator.plan?.progressToAlight ?? -1, 1.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(recorder.schedulerReschedules.count, 1)
        XCTAssertEqual(recorder.schedulerReschedules.first?.stopName, "C")

        coordinator.setAlightStop(code: nil)
        XCTAssertNil(coordinator.plan?.alight)
        XCTAssertNil(coordinator.plan?.progressToAlight)
        XCTAssertEqual(recorder.schedulerCancels, 1)
    }

    func testSetAlightStopIsIgnoredWhenNotFollowing() {
        let recorder = Recorder()
        let coordinator = makeCoordinator(recorder)
        coordinator.setAlightStop(code: "B")
        XCTAssertNil(coordinator.plan)
        XCTAssertTrue(recorder.schedulerReschedules.isEmpty)
    }

    // MARK: voice

    func testVoiceOffMeansNoSpeechAndSilencesTheAnnouncer() {
        let recorder = Recorder()
        let coordinator = makeCoordinator(recorder)
        coordinator.setVoiceEnabled(false)
        XCTAssertEqual(recorder.announcerStops, 1)

        coordinator.start(vehicle: vehicle(), snapshot: snapshot(upcoming: ["B", "C"]))
        coordinator.update(vehicle: vehicle(), snapshot: snapshot(upcoming: ["C"], passed: ["B"]))

        XCTAssertEqual(coordinator.activeEvent, .announce(stop("C", name: "C")), "the card still shows")
        XCTAssertTrue(recorder.speech.isEmpty)
    }

    func testVoiceChoicePersistsInDefaults() {
        let suiteName = "FollowCoordinatorTests.voice"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.removePersistentDomain(forName: suiteName)

        let recorder = Recorder()
        let coordinator = makeCoordinator(recorder, defaults: defaults)
        XCTAssertTrue(coordinator.isVoiceEnabled, "default on (S10)")

        coordinator.setVoiceEnabled(false)
        XCTAssertFalse(defaults.bool(forKey: FollowCoordinator.voiceEnabledKey))

        let reloaded = makeCoordinator(recorder, defaults: defaults)
        XCTAssertFalse(reloaded.isVoiceEnabled)

        reloaded.setVoiceEnabled(true)
        XCTAssertTrue(defaults.bool(forKey: FollowCoordinator.voiceEnabledKey))
    }

    // MARK: cards

    func testDismissEventClearsTheCard() {
        let recorder = Recorder()
        let coordinator = makeCoordinator(recorder)
        coordinator.start(vehicle: vehicle(), snapshot: snapshot(upcoming: ["B", "C"]))
        coordinator.update(vehicle: vehicle(), snapshot: snapshot(upcoming: ["C"], passed: ["B"]))
        XCTAssertNotNil(coordinator.activeEvent)

        coordinator.dismissEvent()
        XCTAssertNil(coordinator.activeEvent)
    }

    // MARK: stop

    func testStopClearsEveryStateAndRestoresTheCamera() {
        let recorder = Recorder()
        let coordinator = makeCoordinator(recorder)
        coordinator.start(vehicle: vehicle(), snapshot: snapshot(upcoming: ["B", "C"], passed: ["A"]))
        coordinator.setAlightStop(code: "C")
        coordinator.is3D = false
        coordinator.isCameraPaused = true

        coordinator.stop()

        XCTAssertFalse(coordinator.isFollowing)
        XCTAssertNil(coordinator.followedVehicleID)
        XCTAssertNil(coordinator.plan)
        XCTAssertNil(coordinator.activeEvent)
        XCTAssertTrue(coordinator.is3D)
        XCTAssertFalse(coordinator.isCameraPaused)
        XCTAssertEqual(recorder.activityEnds, 1)
        XCTAssertEqual(recorder.schedulerCancels, 1)
        XCTAssertEqual(recorder.announcerStops, 1)
        XCTAssertTrue(recorder.speech.isEmpty, "stopping silences speech without announcing")
    }
}
