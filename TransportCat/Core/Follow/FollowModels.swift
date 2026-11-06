import Foundation

// Value types of the follow-vehicle feature (odd/tasks/follow-vehicle.md).
// Mode-agnostic on purpose: the map screens translate their own feeds into
// these values, and every rule (`FollowSession`) and every view reads only
// them. Foundation only, so the rules are tested without a UI.

/// The operator of a followed vehicle (S1). Tot is not followable.
enum FollowMode: String, Equatable, Hashable {
    case metro
    case bus
    case fgc
}

/// The vehicle the rider follows and what the HUD names it by (S1, S4).
struct FollowVehicle: Equatable {
    let mode: FollowMode
    /// The id the screen's feed uses for this vehicle (`TrainPosition.id`,
    /// `BusPosition.id`, `FGCTrain.id`).
    let vehicleID: String
    /// Badge text: "L2", "H12", "S1".
    let lineDisplayName: String
    /// Line colour hex without "#".
    let lineColorHex: String
    /// The head-sign the HUD reads as "cap a <terminus>".
    let terminusName: String
    /// Timetable or arrival-based estimate (metro `isTheoretical`, every
    /// bus); false for FGC's GPS positions.
    let isEstimated: Bool
}

/// One stop along the followed route (S3, S5–S7).
struct FollowStop: Equatable, Identifiable {
    /// Stop code in the operator's space (metro station code, bus stop code,
    /// FGC stop code), as text.
    let code: String
    let name: String
    /// Seconds until the vehicle reaches this stop; nil when the feed has no
    /// ETA (FGC, D1).
    let etaSeconds: Int?
    /// Display names of the other metro lines at this stop ("L4"); empty
    /// when there are none.
    let interchanges: [String]
    /// Facility alert at this stop ("Ascensor fora de servei"); nil when
    /// there is none.
    let facilityNote: String?

    var id: String { code }
}

/// What a map screen knows about the followed vehicle at one moment (S5).
/// Built by the screens from their own feed; the session rules never read a
/// feed themselves.
struct FollowSnapshot: Equatable {
    /// Stops still ahead, in travel order; the first is the next stop.
    let upcoming: [FollowStop]
    /// Stops already passed, in travel order; the last is the stop just left.
    let passed: [FollowStop]
}

/// One cell of the panel's stop strip (S5).
struct FollowStripItem: Equatable, Identifiable {
    enum Role: Equatable {
        case passed
        case next
        case ahead
        case alight
    }

    let stop: FollowStop
    let role: Role

    var id: String { stop.code }
}

/// Everything the HUD, the panel, the map labels and the Live Activity draw
/// (S3–S8). Produced only by `FollowSession.plan`.
struct FollowPlan: Equatable {
    let vehicle: FollowVehicle
    /// The next stop; nil once the vehicle has no stop ahead.
    let next: FollowStop?
    /// Every stop still ahead, in travel order: the alight picker's choices.
    let upcoming: [FollowStop]
    /// The strip: the last passed stop, then the next ones; five cells at
    /// most.
    let strip: [FollowStripItem]
    /// The next stops the map labels, four at most, in travel order.
    let mapLabels: [FollowStop]
    /// The chosen alight stop while it is still ahead.
    let alight: FollowStop?
    /// The stop the alarm fires on: the one before `alight`; nil when there
    /// is none (no choice, or the alight stop is already the next one).
    let alarmStop: FollowStop?
    /// 0...1 progress towards the alight stop, by stop count; nil without an
    /// alight stop.
    let progressToAlight: Double?
}

/// A one-off moment the coordinator surfaces as a card and as speech (S6,
/// S7).
enum FollowEvent: Equatable {
    /// The next stop changed to this stop (S6).
    case announce(FollowStop)
    /// The next stop is the rider's alight stop (S7).
    case alight(FollowStop)
}
