import Foundation

/// The pure state of the v2 status capsule (spec S2): what it shows for one
/// feed's freshness values and the device's connectivity, decided in one place
/// so the map screens and the Parades screens can never disagree.
///
/// Foundation only on purpose, like `Freshness`: the rule is tested without a
/// UI. The SwiftUI view maps the icon and the dot kind to visuals; the wording
/// here is what the rider reads.
///
/// The levels reuse `Freshness.level` and its wording unchanged (tested in
/// `FreshnessTests`): "En directe", "Amb retard", "Dades antigues", "Sense
/// dades", "Sense dades en temps real" and "Horari teòric", with the age as
/// the capsule's detail text. Offline the capsule explains instead that what
/// is drawn comes from saved data and the theoretical timetable — the wording
/// of the offline banner this capsule replaces — and it wins over every
/// freshness level.
enum StatusDotKind: Equatable {
    /// A green dot: a fresh update (spec S7 of the previous design).
    case live
    /// Orange: an update 30–90 s old, or a failed attempt after a live one.
    case delayed
    /// Red: 90 s or more without an update.
    case stale
    /// Gray: no successful update yet, or a feed with no arrivals.
    case unavailable
    /// Blue: a line drawn from the timetable rather than a live feed.
    case theoretical
}

struct StatusCapsuleState: Equatable {
    /// What the capsule draws before the label: a status dot, or the wifi-off
    /// symbol while the device has no network path (spec S2).
    enum Icon: Equatable {
        case dot(StatusDotKind)
        case wifiOff
    }

    let icon: Icon
    /// The main label ("En directe", "Sense connexió"...), in Catalan.
    let label: String
    /// The secondary detail ("fa 12 s", "dades desades i horaris teòrics").
    /// Empty when the level has no age to show.
    let detail: String
}

enum StatusCapsule {
    /// The capsule state for the given connectivity and feed values.
    ///
    /// The precedence mirrors the freshness chip it replaces: offline first,
    /// then the theoretical level, then the empty feed, then the
    /// `Freshness.level` rule (S2 of the previous design).
    static func make(
        isOnline: Bool,
        updatedAt: Date?,
        lastAttemptFailed: Bool,
        feedEmpty: Bool,
        theoretical: Bool,
        now: Date
    ) -> StatusCapsuleState {
        guard isOnline else {
            return StatusCapsuleState(
                icon: .wifiOff,
                label: String(localized: "Sense connexió"),
                detail: String(localized: "dades desades i horaris teòrics")
            )
        }
        // Trains computed from the timetable: the age of the schedule is not a
        // data age, so the capsule says what it is and shows no countdown.
        if theoretical {
            return StatusCapsuleState(
                icon: .dot(.theoretical),
                label: String(localized: "Horari teòric"),
                detail: ""
            )
        }
        // A line TMB publishes no arrivals for is never "En directe", however
        // recent the last empty answer was.
        if feedEmpty {
            return StatusCapsuleState(
                icon: .dot(.unavailable),
                label: String(localized: "Sense dades en temps real"),
                detail: ""
            )
        }
        switch Freshness.level(
            lastUpdate: updatedAt,
            now: now,
            lastAttemptFailed: lastAttemptFailed
        ) {
        case .live:
            return StatusCapsuleState(
                icon: .dot(.live),
                label: String(localized: "En directe"),
                detail: age(of: updatedAt, now: now)
            )
        case .delayed:
            return StatusCapsuleState(
                icon: .dot(.delayed),
                label: String(localized: "Amb retard"),
                detail: age(of: updatedAt, now: now)
            )
        case .stale:
            return StatusCapsuleState(
                icon: .dot(.stale),
                label: String(localized: "Dades antigues"),
                detail: age(of: updatedAt, now: now)
            )
        case .unavailable:
            // No successful poll yet: there is no age to show.
            return StatusCapsuleState(
                icon: .dot(.unavailable),
                label: String(localized: "Sense dades"),
                detail: ""
            )
        }
    }

    /// Age of the last successful update, empty when there is none.
    private static func age(of updatedAt: Date?, now: Date) -> String {
        guard let updatedAt else { return "" }
        return Freshness.ageText(since: updatedAt, now: now)
    }
}
