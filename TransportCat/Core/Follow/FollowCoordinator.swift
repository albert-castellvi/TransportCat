import Foundation
import Observation

/// The hub of a follow session (S1, S5–S10): the map screen that follows a
/// vehicle feeds it snapshots; it computes the plan through `FollowSession`,
/// surfaces announce/alight events, speaks them, and keeps the Live Activity
/// and the alight notification in step. The views read `plan`,
/// `activeEvent` and the toggles; nothing else holds follow state.
///
/// CONTRACT (T0): the members below are fixed. T1 implements the behaviour;
/// the screens and views use them as declared. Adding members is allowed;
/// changing or removing these is not.
@MainActor
@Observable
final class FollowCoordinator {
    static let shared = FollowCoordinator()

    /// UserDefaults key of the voice toggle (S10).
    static let voiceEnabledKey = "followVoiceEnabled"

    /// The current plan while following; nil when nothing is followed.
    private(set) var plan: FollowPlan?
    /// The announce or alight card on screen; nil when there is none.
    private(set) var activeEvent: FollowEvent?
    /// Speech on/off, persisted under `voiceEnabledKey`, default on (S10).
    private(set) var isVoiceEnabled: Bool
    /// Chase camera (3D) or north-up centring (2D) (S2).
    var is3D: Bool = true
    /// A pan paused the chase camera; "Tornar al tren" clears it (S2, D5).
    var isCameraPaused: Bool = false

    private let defaults: UserDefaults

    /// The rider's alight choice; nil when there is none (S5).
    private var alightStopCode: String?
    /// The last snapshot the screens fed, so the alight picker can recompute
    /// the plan on a human-scale event instead of a 10 Hz tick.
    private var lastSnapshot: FollowSnapshot?
    /// The next-stop code the previous update reported, so a stop announces
    /// exactly once (S6).
    private var previousNextCode: String?

    // Side-effecting services, injectable so the tests run without speech,
    // notifications or Live Activities. Defaults wire the shared instances.
    private let activityStart: (FollowPlan) -> Void
    private let activityUpdate: (FollowPlan) -> Void
    private let activityEnd: () -> Void
    private let schedulerReschedule: (Date?, String, String) -> Void
    private let schedulerCancel: () -> Void
    private let announcerSpeak: (String) -> Void
    private let announcerStop: () -> Void

    init(
        defaults: UserDefaults = .standard,
        activityStart: @escaping (FollowPlan) -> Void = { FollowActivityController.shared.start(plan: $0) },
        activityUpdate: @escaping (FollowPlan) -> Void = { FollowActivityController.shared.update(plan: $0) },
        activityEnd: @escaping () -> Void = { FollowActivityController.shared.end() },
        schedulerReschedule: @escaping (Date?, String, String) -> Void = {
            FollowAlightScheduler.reschedule(at: $0, stopName: $1, lineDisplayName: $2)
        },
        schedulerCancel: @escaping () -> Void = { FollowAlightScheduler.cancel() },
        announcerSpeak: @escaping (String) -> Void = { FollowAnnouncer.shared.speak($0) },
        announcerStop: @escaping () -> Void = { FollowAnnouncer.shared.stop() }
    ) {
        self.defaults = defaults
        self.isVoiceEnabled = defaults.object(forKey: Self.voiceEnabledKey) as? Bool ?? true
        self.activityStart = activityStart
        self.activityUpdate = activityUpdate
        self.activityEnd = activityEnd
        self.schedulerReschedule = schedulerReschedule
        self.schedulerCancel = schedulerCancel
        self.announcerSpeak = announcerSpeak
        self.announcerStop = announcerStop
    }

    /// Whether a vehicle is being followed.
    var isFollowing: Bool { plan != nil }

    /// The followed vehicle's feed id, for the screens' markers and camera.
    var followedVehicleID: String? { plan?.vehicle.vehicleID }

    /// Starts following a vehicle (S1). Replaces any previous session.
    func start(vehicle: FollowVehicle, snapshot: FollowSnapshot) {
        stopSession()
        let initialPlan = FollowSession.plan(vehicle: vehicle, snapshot: snapshot, alightStopCode: nil)
        plan = initialPlan
        lastSnapshot = snapshot
        alightStopCode = nil
        previousNextCode = initialPlan.next?.code
        activityStart(initialPlan)
        isCameraPaused = false
    }

    /// Feeds the latest snapshot of the followed vehicle. A vehicle id other
    /// than the followed one is ignored.
    func update(vehicle: FollowVehicle, snapshot: FollowSnapshot) {
        guard let current = plan, current.vehicle.vehicleID == vehicle.vehicleID else { return }
        lastSnapshot = snapshot
        var newPlan = FollowSession.plan(vehicle: current.vehicle, snapshot: snapshot, alightStopCode: alightStopCode)
        if alightStopCode != nil, newPlan.alight == nil {
            // The chosen stop is no longer ahead (the vehicle passed it or the
            // feed renamed it): drop the choice instead of firing late.
            alightStopCode = nil
            newPlan = FollowSession.plan(vehicle: current.vehicle, snapshot: snapshot, alightStopCode: nil)
        }
        // The 10 Hz feed repeats values; skip every side effect until
        // something in the plan actually changed.
        guard newPlan != current else { return }

        if let event = FollowSession.event(previousNextCode: previousNextCode, plan: newPlan) {
            activeEvent = event
            if isVoiceEnabled {
                announcerSpeak(FollowSession.announcementText(for: event))
            }
        }
        previousNextCode = newPlan.next?.code
        plan = newPlan
        activityUpdate(newPlan)
        rescheduleAlightAlarm(for: newPlan)
    }

    /// Picks the alight stop (S5), or clears it with nil.
    func setAlightStop(code: String?) {
        guard let current = plan, let snapshot = lastSnapshot, current.alight?.code != code else { return }
        alightStopCode = code
        let newPlan = FollowSession.plan(vehicle: current.vehicle, snapshot: snapshot, alightStopCode: code)
        plan = newPlan
        rescheduleAlightAlarm(for: newPlan)
    }

    /// Turns speech on or off and persists the choice (S10).
    func setVoiceEnabled(_ enabled: Bool) {
        isVoiceEnabled = enabled
        defaults.set(enabled, forKey: Self.voiceEnabledKey)
        if !enabled {
            announcerStop()
        }
    }

    /// Dismisses the card on screen ("D'acord", S7).
    func dismissEvent() {
        activeEvent = nil
    }

    /// Stops following (S9).
    func stop() {
        stopSession()
    }

    /// Ends the session and every side effect it holds (S9); also tear-down
    /// before a replacement session starts. A session that was not running
    /// touches no service: there is nothing scheduled or speaking.
    private func stopSession() {
        if plan != nil {
            activityEnd()
            schedulerCancel()
            announcerStop()
        }
        plan = nil
        activeEvent = nil
        alightStopCode = nil
        previousNextCode = nil
        lastSnapshot = nil
        is3D = true
        isCameraPaused = false
    }

    /// Keeps the alight notification in step with the plan: rescheduled for
    /// the stop before the alight stop, or cancelled without one (S8).
    private func rescheduleAlightAlarm(for newPlan: FollowPlan) {
        if let alight = newPlan.alight {
            schedulerReschedule(
                FollowSession.alightAlarmDate(plan: newPlan, now: Date()),
                alight.name,
                newPlan.vehicle.lineDisplayName
            )
        } else {
            schedulerCancel()
        }
    }
}
