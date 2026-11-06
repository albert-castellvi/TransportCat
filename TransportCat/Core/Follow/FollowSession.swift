import Foundation

/// The pure rules of a follow session (S5–S8). Foundation only, no clock and
/// no feed: everything comes in as values, so `FollowSessionTests` covers
/// every case.
///
/// CONTRACT (T0): the signatures below are fixed. T1 implements the bodies;
/// the other units call them as declared.
enum FollowSession {
    /// The plan the HUD, the panel, the labels and the Live Activity draw,
    /// for the vehicle's current snapshot and the rider's alight choice
    /// (`nil` when there is none, or when the code is not a stop ahead).
    static func plan(
        vehicle: FollowVehicle,
        snapshot: FollowSnapshot,
        alightStopCode: String?
    ) -> FollowPlan {
        FollowPlan(
            vehicle: vehicle,
            next: snapshot.upcoming.first,
            upcoming: snapshot.upcoming,
            strip: [],
            mapLabels: [],
            alight: nil,
            alarmStop: nil,
            progressToAlight: nil
        )
    }

    /// The event to surface when the next stop changed from
    /// `previousNextCode` to `plan.next`: `.alight` when the new next stop is
    /// the alight stop, `.announce` otherwise; nil when the next stop did not
    /// change or there is none.
    static func event(previousNextCode: String?, plan: FollowPlan) -> FollowEvent? {
        nil
    }

    /// The Catalan sentence the announcer speaks for an event (S6, S7).
    static func announcementText(for event: FollowEvent) -> String {
        ""
    }

    /// The countdown a stop shows: "ara" when imminent, else
    /// `Arrival.countdownText`; nil without an ETA (FGC, D1).
    static func etaText(for stop: FollowStop) -> String? {
        nil
    }

    /// When the "Baixa a la pròxima" notification should fire: `now` plus the
    /// alarm stop's ETA; nil without an alarm stop or without an ETA (S8).
    static func alightAlarmDate(plan: FollowPlan, now: Date) -> Date? {
        nil
    }
}
