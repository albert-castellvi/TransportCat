import Foundation

/// One grouped incident badge of the Tot map (spec S7, decision D6): the
/// service alerts of one or more metro lines that share their first affected
/// station. The map draws one `IncidentBadge` for it at the badge's station,
/// and the tap opens a glass card listing `alerts`.
struct GlobalIncidentBadge: Identifiable, Equatable {
    /// The line-independent station identity the badge sits on.
    let id: String
    let stationCode: Int
    let stationName: String
    let position: GeoPoint
    /// Display names of the affected lines ("L1", "L5"), in feed order.
    let lineNames: [String]
    /// What the badge shows: the single line's display name, or the grouped
    /// count ("2 línies") when several lines share the station.
    let badgeText: String
    /// Every service alert behind the badge, in feed order, deduplicated.
    let alerts: [ServiceAlert]
}

/// The grouping rule of the Tot incidents (spec S7, decision D6), pure so the
/// map derives it off the render path and the tests can pin it.
///
/// For every line that has at least one service alert the rule places one
/// badge at that line's FIRST affected station — the one earliest in the
/// line's own station order when the line state provides it, the first one in
/// feed order otherwise. Badges that land on the same station merge into one,
/// whose text is "<n> línies". Facility alerts never join a badge: they live
/// on stations, and only `AlertSeverity.service` disruptions produce badges.
/// FGC has no alert source at all (decision D2), so feeds here are always
/// the metro ones.
enum GlobalIncidentBadges {
    /// Groups the map's incident stations into badges.
    ///
    /// - Parameters:
    ///   - incidentStations: stations with active incidents, in feed order,
    ///     as `GlobalNetworkState.refreshIncidents` publishes them.
    ///   - orderOfStation: the position of a station inside a line, looked up
    ///     by the line code and the station's line-independent id from the
    ///     loaded line states; nil falls back to feed order.
    static func badges(
        from incidentStations: [GlobalIncidentStation],
        orderOfStation: (_ lineCode: String, _ stationID: String) -> Int?
    ) -> [GlobalIncidentBadge] {
        guard !incidentStations.isEmpty else { return [] }

        // Which service alerts tie each line to each incident station, in
        // feed order. A line enters the map the first time an alert names it.
        var assignmentsByLine: [String: [(stationIndex: Int, alert: ServiceAlert)]] = [:]
        var lineOrder: [String] = []
        for (index, incident) in incidentStations.enumerated() {
            for alert in incident.alerts where alert.severity == .service {
                for lineCode in alert.lineCodes where !lineCode.isEmpty {
                    if assignmentsByLine[lineCode] == nil {
                        lineOrder.append(lineCode)
                    }
                    assignmentsByLine[lineCode, default: []].append((index, alert))
                }
            }
        }

        // The first affected station of each line: the smallest station order
        // the line state knows, tie-broken by feed order; with no order data
        // at all, plain feed order (earliest station index) wins.
        var firstStationByLine: [String: Int] = [:]
        for lineCode in lineOrder {
            var best: (order: Int, stationIndex: Int)?
            for assignment in assignmentsByLine[lineCode] ?? [] {
                let order = orderOfStation(lineCode, incidentStations[assignment.stationIndex].id) ?? Int.max
                if let current = best {
                    if order < current.order
                        || (order == current.order && assignment.stationIndex < current.stationIndex) {
                        best = (order, assignment.stationIndex)
                    }
                } else {
                    best = (order, assignment.stationIndex)
                }
            }
            firstStationByLine[lineCode] = best?.stationIndex
        }

        // Lines whose first affected station is the same one merge into one
        // badge; each line keeps only its alerts at that station.
        struct Group {
            let stationIndex: Int
            var lineNames: [String] = []
            var alerts: [ServiceAlert] = []
            var alertIDs: Set<String> = []
        }
        var groupsByStation: [String: Group] = [:]
        var groupOrder: [String] = []
        for lineCode in lineOrder {
            guard let stationIndex = firstStationByLine[lineCode] else { continue }
            let incident = incidentStations[stationIndex]
            let lineName = MetroLine.line(forCode: lineCode)?.displayName ?? lineCode
            var group = groupsByStation[incident.id] ?? Group(stationIndex: stationIndex)
            if group.lineNames.isEmpty {
                groupOrder.append(incident.id)
            }
            group.lineNames.append(lineName)
            for assignment in assignmentsByLine[lineCode] ?? []
            where assignment.stationIndex == stationIndex
                    && !group.alertIDs.contains(assignment.alert.id) {
                group.alertIDs.insert(assignment.alert.id)
                group.alerts.append(assignment.alert)
            }
            groupsByStation[incident.id] = group
        }

        return groupOrder.compactMap { stationID in
            guard let group = groupsByStation[stationID] else { return nil }
            let incident = incidentStations[group.stationIndex]
            return GlobalIncidentBadge(
                id: incident.id,
                stationCode: incident.stationCode,
                stationName: incident.name,
                position: incident.position,
                lineNames: group.lineNames,
                badgeText: group.lineNames.count == 1
                    ? group.lineNames[0]
                    : "\(group.lineNames.count) línies",
                alerts: group.alerts
            )
        }
    }
}
