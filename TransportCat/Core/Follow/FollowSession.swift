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
        let next = snapshot.upcoming.first
        // The chosen stop only counts while it is still ahead.
        let alight = alightStopCode.flatMap { code in
            snapshot.upcoming.first { $0.code == code }
        }

        var strip: [FollowStripItem] = []
        if let lastPassed = snapshot.passed.last {
            strip.append(FollowStripItem(stop: lastPassed, role: .passed))
        }
        for stop in snapshot.upcoming where strip.count < 5 {
            let role: FollowStripItem.Role
            if stop == alight {
                role = .alight
            } else if stop == next {
                role = .next
            } else {
                role = .ahead
            }
            strip.append(FollowStripItem(stop: stop, role: role))
        }

        var progressToAlight: Double?
        if let alight, let index = snapshot.upcoming.firstIndex(where: { $0 == alight }) {
            // Station-banded progress: passed stops / (passed + ahead + the
            // alight stop itself), so 0 means "just left the last stop" and
            // the value approaches 1 as the vehicle nears the alight stop.
            let passed = snapshot.passed.count
            let raw = Double(passed) / Double(passed + index + 1)
            progressToAlight = min(max(raw, 0), 1)
        }

        return FollowPlan(
            vehicle: vehicle,
            next: next,
            upcoming: snapshot.upcoming,
            strip: strip,
            mapLabels: Array(snapshot.upcoming.prefix(4)),
            alight: alight,
            alarmStop: alarmStop(upcoming: snapshot.upcoming, alight: alight),
            progressToAlight: progressToAlight
        )
    }

    /// The stop before `alight` in travel order; nil when there is no alight
    /// stop or it is already the next stop (nothing left to warn about).
    private static func alarmStop(upcoming: [FollowStop], alight: FollowStop?) -> FollowStop? {
        guard let alight, let index = upcoming.firstIndex(where: { $0 == alight }), index > 0 else {
            return nil
        }
        return upcoming[index - 1]
    }

    /// The event to surface when the next stop changed from
    /// `previousNextCode` to `plan.next`: `.alight` when the new next stop is
    /// the alight stop, `.announce` otherwise; nil when the next stop did not
    /// change or there is none.
    static func event(previousNextCode: String?, plan: FollowPlan) -> FollowEvent? {
        guard let next = plan.next, next.code != previousNextCode else { return nil }
        if plan.alight == next {
            return .alight(next)
        }
        return .announce(next)
    }

    /// The Catalan sentence the announcer speaks for an event (S6, S7).
    static func announcementText(for event: FollowEvent) -> String {
        let prefix: String
        let stop: FollowStop
        switch event {
        case .announce(let announced):
            prefix = "Pròxima parada"
            stop = announced
        case .alight(let alight):
            prefix = "Baixa a la pròxima"
            stop = alight
        }
        var text = "\(prefix): \(stop.name)."
        if !stop.interchanges.isEmpty {
            text += " Correspondència amb \(interchangePhrase(stop.interchanges))."
        }
        if case .announce = event, let facilityNote = stop.facilityNote {
            text += " \(facilityNote)."
        }
        return text
    }

    /// Interchange list as spoken text: "la L4", "la L1 i la L4",
    /// "la L1, la L3 i la L4".
    private static func interchangePhrase(_ names: [String]) -> String {
        let items = names.map { "la \($0)" }
        guard items.count > 1 else {
            return items.first ?? ""
        }
        return items.dropLast().joined(separator: ", ") + " i " + (items.last ?? "")
    }

    /// The countdown a stop shows: "ara" when imminent, else
    /// `Arrival.countdownText`; nil without an ETA (FGC, D1).
    static func etaText(for stop: FollowStop) -> String? {
        guard let etaSeconds = stop.etaSeconds else { return nil }
        return etaSeconds <= 60 ? "ara" : Arrival.countdownText(seconds: etaSeconds)
    }

    /// When the "Baixa a la pròxima" notification should fire: `now` plus the
    /// alarm stop's ETA; nil without an alarm stop or without an ETA (S8).
    static func alightAlarmDate(plan: FollowPlan, now: Date) -> Date? {
        guard let alarmStop = plan.alarmStop, let etaSeconds = alarmStop.etaSeconds else {
            return nil
        }
        return now.addingTimeInterval(TimeInterval(etaSeconds))
    }
}
