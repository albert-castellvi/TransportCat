import Foundation

/// A metro line as shown in the app.
struct MetroLine: Identifiable, Hashable {
    /// TMB `CODI_LINIA` used in API paths and alerts: "1"..."5", "11", and the
    /// numeric codes of the lettered lines ("94" = L9N, "91" = L9S, "104" = L10N,
    /// "101" = L10S, "99" = FM). Names like "9N" return HTTP 404.
    let code: String
    /// Human-readable name, e.g. "L1", "L9N", "FM".
    let displayName: String
    /// Display color as hex without "#", taken from TMB network data
    /// (`COLOR_LINIA` in the transit service, `color_linia` in i-Metro, which
    /// agree). Every line has one, so these are brand values and not guesses.
    let colorHex: String

    var id: String { code }
}

extension MetroLine {
    static let allLines: [MetroLine] = [
        MetroLine(code: "1", displayName: "L1", colorHex: "CE1126"),
        MetroLine(code: "2", displayName: "L2", colorHex: "93248F"),
        MetroLine(code: "3", displayName: "L3", colorHex: "1EB53A"),
        MetroLine(code: "4", displayName: "L4", colorHex: "F7A30E"),
        MetroLine(code: "5", displayName: "L5", colorHex: "005A97"),
        MetroLine(code: "94", displayName: "L9N", colorHex: "FB712B"),
        MetroLine(code: "91", displayName: "L9S", colorHex: "FB712B"),
        MetroLine(code: "104", displayName: "L10N", colorHex: "00A6D6"),
        MetroLine(code: "101", displayName: "L10S", colorHex: "00A6D6"),
        MetroLine(code: "11", displayName: "L11", colorHex: "89B94C"),
        MetroLine(code: "99", displayName: "FM", colorHex: "004C38"),
    ]

    static func line(forCode code: String) -> MetroLine? {
        allLines.first { $0.code == code }
    }
}
