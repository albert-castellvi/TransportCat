import Foundation

/// A metro line as shown in the app.
struct MetroLine: Identifiable, Hashable {
    /// TMB line code used in API paths: "1", "2", ..., "11", "9N", "9S", "10N", "10S", "FM".
    let code: String
    /// Human-readable name, e.g. "L1", "L9N", "FM".
    let displayName: String
    /// Display color as hex without "#". Some lines have no color in the TMB
    /// network data, so these are display approximations.
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
        MetroLine(code: "9N", displayName: "L9N", colorHex: "F7941D"),
        MetroLine(code: "9S", displayName: "L9S", colorHex: "F7941D"),
        MetroLine(code: "10N", displayName: "L10N", colorHex: "00A0AF"),
        MetroLine(code: "10S", displayName: "L10S", colorHex: "00A0AF"),
        MetroLine(code: "11", displayName: "L11", colorHex: "89B94C"),
        MetroLine(code: "FM", displayName: "FM", colorHex: "D6A400"),
    ]

    static func line(forCode code: String) -> MetroLine? {
        allLines.first { $0.code == code }
    }
}
