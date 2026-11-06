import Foundation

/// Where the single amber badge of an affected run sits on the map (spec S7):
/// one badge per run, at the run's middle station, carrying the line display
/// name and the alert the badge's card shows. Foundation-only and pure, so the
/// Linux harness tests it.
struct IncidentRunBadge: Equatable, Identifiable {
    /// `IncidentRun.id` of the run the badge belongs to.
    let runID: Int
    /// "L2", "H12": the display name of the affected line.
    let text: String
    /// The alert the badge's glass card shows.
    let alertID: String
    let latitude: Double
    let longitude: Double

    var id: Int { runID }
}

enum IncidentBadgePlacement {
    /// The middle station of a run: the station the badge sits above (spec S7,
    /// "al mig del tram"). An odd count has an exact middle; an even count
    /// takes the later of the two half points so the badge never hides the end
    /// station the rider reads the run from.
    static func middleStation(of run: IncidentRun) -> Station? {
        middleStation(of: run.stations)
    }

    /// Array form of the rule above; see the `IncidentRun` one.
    static func middleStation(of stations: [Station]) -> Station? {
        guard !stations.isEmpty else { return nil }
        return stations[stations.count / 2]
    }

    /// Text of a run's badge: the display name of the affected line ("L2",
    /// "H12"), the same badge the status chrome and the pickers show.
    static func badgeText(lineDisplayName: String) -> String {
        lineDisplayName
    }

    /// The alert id a run's card shows: the first alert of the run's first
    /// affected station, so a run fed by several alerts keeps one stable card
    /// while it lasts (the same rule `ParadesTimeline.serviceCardAlertIDs`
    /// applies to the Parades cards).
    static func primaryAlertID(
        of run: IncidentRun,
        serviceIncidents: [Int: [StationIncident]]
    ) -> String? {
        for station in run.stations {
            if let first = serviceIncidents[station.code]?.first {
                return first.alertID
            }
        }
        return nil
    }

    /// The badge of one run, or nil when the run has no affected station or no
    /// resolvable alert. Callers pass the service-only incident dictionary the
    /// run was built from, so a facility incident of the same station never
    /// leaks into the badge's card.
    static func badge(
        for run: IncidentRun,
        lineDisplayName: String,
        serviceIncidents: [Int: [StationIncident]]
    ) -> IncidentRunBadge? {
        guard let middle = middleStation(of: run),
              let alertID = primaryAlertID(of: run, serviceIncidents: serviceIncidents) else {
            return nil
        }
        return IncidentRunBadge(
            runID: run.id,
            text: badgeText(lineDisplayName: lineDisplayName),
            alertID: alertID,
            latitude: middle.latitude,
            longitude: middle.longitude
        )
    }
}
