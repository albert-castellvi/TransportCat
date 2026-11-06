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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.isVoiceEnabled = defaults.object(forKey: Self.voiceEnabledKey) as? Bool ?? true
    }

    /// Whether a vehicle is being followed.
    var isFollowing: Bool { plan != nil }

    /// The followed vehicle's feed id, for the screens' markers and camera.
    var followedVehicleID: String? { plan?.vehicle.vehicleID }

    /// Starts following a vehicle (S1). Replaces any previous session.
    func start(vehicle: FollowVehicle, snapshot: FollowSnapshot) {
        plan = FollowSession.plan(vehicle: vehicle, snapshot: snapshot, alightStopCode: nil)
    }

    /// Feeds the latest snapshot of the followed vehicle. A vehicle id other
    /// than the followed one is ignored.
    func update(vehicle: FollowVehicle, snapshot: FollowSnapshot) {}

    /// Picks the alight stop (S5), or clears it with nil.
    func setAlightStop(code: String?) {}

    /// Turns speech on or off and persists the choice (S10).
    func setVoiceEnabled(_ enabled: Bool) {}

    /// Dismisses the card on screen ("D'acord", S7).
    func dismissEvent() {}

    /// Stops following (S9).
    func stop() {
        plan = nil
        activeEvent = nil
    }
}
