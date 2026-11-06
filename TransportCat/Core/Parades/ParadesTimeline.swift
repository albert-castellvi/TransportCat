import Foundation

/// The time column of one direction of one station row (spec S8).
enum ParadesTimeText: Equatable {
    /// The next train of the direction is imminent: shown in green ("ara").
    case now
    /// A countdown ("2 min", the wording `Arrival.countdownText` uses).
    case minutes(String)
    /// The feed reports no train for this direction ("—").
    case none

    /// The plain text the column draws.
    var text: String {
        switch self {
        case .now: return "ara"
        case .minutes(let text): return text
        case .none: return "—"
        }
    }

    /// Green only for "ara"; "—" and countdowns keep the row's default color.
    var isImminent: Bool {
        if case .now = self { return true }
        return false
    }
}

/// Pure row-model rules of the Parades screens (specs S8, S9). Foundation-only
/// and `nonisolated` so the Linux harness can test them: every rule is a pure
/// function of what `LineState` / `BusLineState` already expose — the state
/// types are never modified here (redesign-v2 T2 constraints).
enum ParadesTimeline {
    /// Seconds at or below which an arrival reads as imminent ("ara").
    /// The feed clamps overdue trains at 0, so anything under one minute is
    /// effectively "at the platform now".
    static let imminentThresholdSeconds = 60

    // MARK: - Metro time columns

    /// The two right-aligned time columns of one station row (spec S8): soonest
    /// arrival per direction (`via` 1 toward the last station, 2 toward the
    /// first), exactly as the old pills chose, rendered as plain tabular text.
    ///
    /// "ara" when the soonest arrival is at most `imminentThresholdSeconds`
    /// away; otherwise `Arrival.countdownText`; "—" when the direction has no
    /// arrival with a countdown at all.
    static func metroColumn(
        arrivals: [Arrival],
        via: Int
    ) -> ParadesTimeText {
        let soonest = arrivals
            .filter { $0.via == via && $0.seconds != nil }
            .min { ($0.seconds ?? .max) < ($1.seconds ?? .max) }
        guard let seconds = soonest?.seconds else { return .none }
        if seconds <= imminentThresholdSeconds { return .now }
        return .minutes(Arrival.countdownText(seconds: seconds))
    }

    // MARK: - Metro termini header

    /// "Paral·lel · Badalona"-style termini pair (spec S8): the first and the
    /// last station of the line in `orderInLine` order. The names are stated
    /// once here, in the sticky header — no row repeats its direction's
    /// destination. Stations without both ends are not a displayable line:
    /// the caller hides the header.
    static func metroTerminiNames(in stations: [Station]) -> (first: String, last: String)? {
        guard let first = stations.min(by: { $0.orderInLine < $1.orderInLine }),
              let last = stations.max(by: { $0.orderInLine < $1.orderInLine }),
              first.code != last.code else { return nil }
        return (first.name, last.name)
    }

    // MARK: - Nearest station ("Ets aquí · <distance>")

    /// Which station of the line is nearest to `userLocation`: the one with the
    /// smallest straight-line distance, ties broken by station code so the
    /// answer is deterministic. Nil when the line has no stations, the user has
    /// no fix yet, or a station carries no usable coordinates — those are
    /// skipped, never crash the pick.
    static func nearestStation(
        stations: [Station],
        userLocation: GeoPoint?
    ) -> (station: Station, distanceMeters: Double)? {
        guard let userLocation else { return nil }
        var best: (station: Station, distanceMeters: Double)?
        for station in stations {
            let distance = GeoMath.distanceMeters(
                from: userLocation,
                to: GeoPoint(latitude: station.latitude, longitude: station.longitude)
            )
            if best == nil
                || distance < best!.distanceMeters
                || (distance == best!.distanceMeters && station.code < best!.station.code) {
                best = (station, distance)
            }
        }
        return best
    }

    /// "Ets aquí · 250 m" (spec S8). Whole meters under a kilometer, one
    /// decimal in kilometers above, matching the mockup's "250 m".
    static func hereText(distanceMeters: Double) -> String {
        let clamped = max(0, distanceMeters.rounded())
        if clamped < 1_000 { return "Ets aquí · \(Int(clamped)) m" }
        let tenths = Int((clamped / 100).rounded())
        return "Ets aquí · \(tenths / 10),\(tenths % 10) km"
    }

    // MARK: - Metro interchange badges

    /// Metro–metro interchange badges of one station (D4): the display names of
    /// the OTHER metro lines that serve it, in `MetroLine.allLines` order.
    ///
    /// The source is the places catalog (`PlaceCatalogStore.places`), whose
    /// metro places carry every line of the station as display names ("L1").
    /// It is cached on disk, so the badges exist in the Metro mode without the
    /// global state having run (fix F1). Interchange identity is the folded
    /// name match the feed itself uses. The line on screen is never listed,
    /// and codes that are not metro lines are skipped.
    static func metroInterchangeNames(
        stationName: String,
        lineDisplayName: String,
        places: [Place]
    ) -> [String] {
        let needle = normalized(stationName)
        guard !needle.isEmpty else { return [] }
        var served: Set<String> = []
        for place in places where place.kind == .metroStation && normalized(place.name) == needle {
            served.formUnion(place.lineCodes)
        }
        served.remove(lineDisplayName)
        return MetroLine.allLines.map(\.displayName).filter { served.contains($0) }
    }

    private static func normalized(_ text: String) -> String {
        text.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "ca_ES")
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Alert counts, one source

    /// Severity bucket of one active incident: the facility kinds the spec
    /// names inline in grey (lift, escalator, closed access) versus everything
    /// else. The single source both the row rendering and the counts read, so
    /// they can never disagree (spec S8, "alert counts from one source").
    static func isFacilityIncident(_ incident: StationIncident) -> Bool {
        switch incident.kind {
        case .escalator, .elevator, .accessClosed: return true
        case .stopClosed, .detour, .other: return false
        }
    }

    /// One service card per affected run, for the top of the metro screen
    /// (spec S8): the first alert of each consecutive run of affected
    /// stations, keyed by alert id so a run fed by several alerts names the
    /// first one only. Empty when nothing is affected.
    static func serviceCardAlertIDs(
        stations: [Station],
        incidents: [Int: [StationIncident]]
    ) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for station in stations.sorted(by: { $0.orderInLine < $1.orderInLine }) {
            guard let first = incidents[station.code]?.first, !seen.contains(first.alertID) else { continue }
            seen.insert(first.alertID)
            result.append(first.alertID)
        }
        return result
    }

    // MARK: - Rail shape

    /// Whether the rail segment leaving a station toward the next one is
    /// dotted: true when the segment belongs to an affected run, so the rail is
    /// "dotted on affected runs" without repainting the colour (spec S8). The
    /// station itself is never marked, only the edge after it; the last
    /// station has no edge.
    ///
    /// `affectedCodes` is `IncidentIndex.incidents` keyed by station code.
    static func isEdgeAffected(
        fromStationCode code: Int,
        nextStationCode: Int?,
        affectedCodes: Set<Int>
    ) -> Bool {
        guard let nextStationCode else { return false }
        return affectedCodes.contains(code) || affectedCodes.contains(nextStationCode)
    }

    // MARK: - Bus rows

    /// The next two buses of one stop of one direction (spec S9): the two
    /// soonest arrivals of that direction, big first, smaller second. A stop
    /// with one arrival shows one, a stop with none shows "Sense dada" at the
    /// row level.
    static func busNextTwo(
        arrivals: [BusArrival],
        directionID: Int
    ) -> (next: BusArrival?, after: BusArrival?) {
        let sorted = arrivals
            .filter { $0.directionID == directionID }
            .sorted { $0.seconds < $1.seconds }
        return (sorted.first, sorted.count > 1 ? sorted[1] : nil)
    }

    /// The plain time text of one bus arrival, same wording as the metro
    /// countdown: the imminent case reads "ara", "—" never happens for a bus
    /// (iBus always carries seconds), so the rule is only imminent/countdown.
    static func busTimeText(seconds: Int) -> String {
        seconds <= imminentThresholdSeconds
            ? "ara"
            : Arrival.countdownText(seconds: seconds)
    }
}

