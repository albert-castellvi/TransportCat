import Foundation

/// How badly an alert hits the service, from its TMB effect type
/// (`categories.effect_type`): a service interruption outranks a facility out
/// of order. `Comparable` so callers can pick the highest severity of a list.
enum AlertSeverity: Int, Comparable {
    case facility = 0
    case service = 1

    static func < (lhs: AlertSeverity, rhs: AlertSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

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
    /// TMB effect type (`categories.effect_type`): TRAFFIC for service
    /// interruptions, INFRASTRUCTURE for facilities out of order. Bus alerts
    /// put their `categories.messageType` (ALTERATION, SERVICE_MESSAGE) here.
    var effectType: String? = nil
    /// Alert kind as free text (`typeName`): "Parada anul·lada amb parada
    /// alternativa nova", "Modificació del recorregut ...". Metro alerts carry
    /// no `typeName`, and their kind comes from `effectCode` instead.
    var typeName: String? = nil

    /// An alert is active when it already began (or has no begin date) and has
    /// not ended yet (or has no end date).
    func isActive(now: Date) -> Bool {
        if let begin = beginDate, begin > now { return false }
        if let end = endDate, end < now { return false }
        return true
    }

    /// Service when TMB flags the alert as a traffic disruption; every other
    /// kind (infrastructure, missing type) is a facility-level alert.
    var severity: AlertSeverity {
        effectType?.caseInsensitiveCompare("TRAFFIC") == .orderedSame ? .service : .facility
    }
}
