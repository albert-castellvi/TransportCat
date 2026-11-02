import Foundation

/// Presentation-ready text of a service alert (spec S7).
///
/// The TMB feeds ship HTML in the alert copy ("…<br>Si els necessites…").
/// `IncidentIndex` already cleans it for the diagram, but its cleaner is
/// file-private, so the sheet gets the same rule here: line breaks become
/// spaces, every other tag is dropped, runs of whitespace collapse, and empty
/// text becomes nil.
enum AlertText {
    static func cleaned(_ html: String?) -> String? {
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

    /// Catalan label of an alert's effect, from the metro `effect_code` /
    /// `effect_type` or the bus `typeName` (spec S7).
    static func effect(for alert: ServiceAlert) -> String? {
        if let code = alert.effectCode?.uppercased() {
            switch code {
            case "PP9": return "Escala mecànica fora de servei"
            case "PP8": return "Ascensor fora de servei"
            case "PP7": return "Accés tancat"
            case "PP2": return "Corredors tancats"
            default: break
            }
        }
        if let typeName = alert.typeName, !typeName.isEmpty {
            return typeName
        }
        if let effectType = alert.effectType, !effectType.isEmpty {
            switch effectType.uppercased() {
            case "TRAFFIC": return "Afectació del servei"
            case "INFRASTRUCTURE": return "Afectació a la infraestructura"
            case "ALTERATION": return "Alteració del servei"
            case "SERVICE_MESSAGE": return "Avís de servei"
            default: return effectType
            }
        }
        return nil
    }
}
