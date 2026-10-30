import Foundation

/// A service disruption from the TMB alerts feed
/// (`/v1/alerts/metro/channels/WEB`).
struct ServiceAlert: Identifiable, Hashable {
    let id: String
    /// Affected line codes, normalized to strings ("2", "94", ...).
    let lineCodes: [String]
    /// Affected station names as listed by TMB.
    let stationNames: [String]
    let beginDate: Date?
    let endDate: Date?
    /// Description text when TMB provides one.
    let text: String?

    /// Affected station codes (`entities[].station_code`, "136" -> 136).
    /// The feed sends "ALL" when the alert covers a whole line, which is not
    /// a station code and is therefore dropped while parsing.
    var stationCodes: [Int] = []
    /// Access names the alert closes (`entities[].entrance_name`); "ALL" and
    /// absent entrances are dropped while parsing.
    var entranceNames: [String] = []
    /// TMB effect code (`categories.effect_code`): PP2 corridors closed,
    /// PP7 access closed, PP8 elevator out, PP9 escalator out.
    var effectCode: String? = nil
}
