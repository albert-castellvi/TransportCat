import Foundation

/// What a service alert does to a station, derived from the TMB effect code
/// (`categories.effect_code`): PP9 escalator out, PP8 elevator out, PP7 access
/// closed; everything else (PP2 corridors closed, ...) stays `other`.
enum IncidentKind: String, Hashable {
    case escalator
    case elevator
    case accessClosed
    case other
}

/// One active incident at one station, ready to be shown by the diagram.
struct StationIncident: Identifiable, Hashable {
    /// "<alertID>-<stationCode>", unique per station row.
    let id: String
    let alertID: String
    let kind: IncidentKind
    /// Catalan title, e.g. "Accés tancat: Santa Madrona".
    let title: String
    /// Alert description with the HTML markup removed; nil when empty.
    let text: String?
    /// Closed access name, when the alert names one.
    let entrance: String?
}

/// Turns the alerts feed into per-station incidents for the Xarxa diagram.
enum IncidentIndex {
    /// Incidents of one line, keyed by `Station.code`. Stations without an
    /// incident are absent from the dictionary; each station lists its
    /// incidents by alert id ascending.
    static func incidents(
        for alerts: [ServiceAlert],
        stations: [Station],
        lineCode: String,
        now: Date = Date()
    ) -> [Int: [StationIncident]] {
        var result: [Int: [StationIncident]] = [:]
        for station in stations {
            let matching = alerts.filter { alert in
                alert.isActive(now: now) && alert.lineCodes.contains(lineCode) && covers(alert, station: station)
            }
            guard !matching.isEmpty else { continue }
            result[station.code] = matching
                .map { incident(for: $0, station: station) }
                .sorted { $0.alertID < $1.alertID }
        }
        return result
    }

    /// A station matches by code; the name comparison is only a fallback for
    /// alerts that carry no station code at all (the feed sends names for
    /// some line-wide disruptions).
    private static func covers(_ alert: ServiceAlert, station: Station) -> Bool {
        guard alert.stationCodes.isEmpty else {
            return alert.stationCodes.contains(station.code)
        }
        let normalizedStation = normalizedName(station.name)
        return alert.stationNames.contains { normalizedName($0) == normalizedStation }
    }

    /// Case- and diacritic-insensitive comparison ("Pl. Catalunya" matches
    /// "Pl. Catalunya" as well as "PL. CATALUNYA").
    private static func normalizedName(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "ca_ES"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func incident(for alert: ServiceAlert, station: Station) -> StationIncident {
        let kind = kind(for: alert.effectCode)
        let entrance = alert.entranceNames.first
        let text = plainText(from: alert.text)
        return StationIncident(
            id: "\(alert.id)-\(station.code)",
            alertID: alert.id,
            kind: kind,
            title: title(for: kind, entrance: entrance, text: text),
            text: text,
            entrance: entrance
        )
    }

    private static func kind(for effectCode: String?) -> IncidentKind {
        switch effectCode?.uppercased() {
        case "PP9": return .escalator
        case "PP8": return .elevator
        case "PP7": return .accessClosed
        default: return .other
        }
    }

    private static func title(for kind: IncidentKind, entrance: String?, text: String?) -> String {
        switch kind {
        case .escalator: return "Escala mecànica fora de servei"
        case .elevator: return "Ascensor fora de servei"
        case .accessClosed:
            guard let entrance, !entrance.isEmpty else { return "Accés tancat" }
            return "Accés tancat: \(entrance)"
        case .other: return firstSentence(from: text)
        }
    }

    /// Used when the text says nothing usable.
    private static let genericTitle = "Incidència a l'estació"
    /// Longest snippet taken from a text that has no sentence break.
    private static let maxTitleLength = 70

    /// The first sentence of the alert text, so the diagram says what actually
    /// happens instead of a generic label. The cut is at the first ". "; a sentence
    /// longer than `maxTitleLength` is cut at a word boundary with an ellipsis. Missing or
    /// empty text keeps the generic title.
    private static func firstSentence(from text: String?) -> String {
        guard let text, !text.isEmpty else { return genericTitle }
        var sentence = text
        if let separator = text.range(of: ". ") {
            let head = String(text[text.startIndex..<separator.lowerBound])
            if !head.isEmpty { sentence = head }
        }
        guard sentence.count > maxTitleLength else { return sentence }
        // Cut at the last word boundary inside the limit so no word is split.
        var cut = String(sentence.prefix(maxTitleLength))
        if let lastSpace = cut.lastIndex(of: " ") { cut = String(cut[cut.startIndex..<lastSpace]) }
        return cut.trimmingCharacters(in: .whitespaces) + "…"
    }

    /// The feed ships HTML in `textCa` ("...<br>Si els necessites..."). Line
    /// breaks become spaces, every other tag is dropped, runs of whitespace
    /// collapse and the result is trimmed; empty text becomes nil.
    private static func plainText(from html: String?) -> String? {
        guard let html else { return nil }
        var text = html.replacingOccurrences(
            of: "<br\\s*/?>",
            with: " ",
            options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
