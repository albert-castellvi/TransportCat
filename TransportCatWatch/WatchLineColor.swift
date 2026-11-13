import SwiftUI

/// Line colours on the wrist (review W6).
///
/// Metro lines carry their brand colour in `MetroLine.allLines`, which the watch
/// already compiles, and the hex-to-colour and luminance rules are the app's own
/// (`Color(hex:)`, `HexLuminance`), so a badge looks the same as on the phone.
/// Bus and FGC colours live in catalogs the watch does not fetch for a badge, so
/// those badges stay neutral instead of guessing.
enum WatchLineColor {
    /// The grey of a line with no known colour.
    static let neutralHex = LineColorHex.neutralHex

    /// The colour the phone paints an imminent arrival with (spec S12).
    static let imminentHex = "30D158"

    /// The line colour of `line` at `place`, or nil when the watch has no
    /// source for it.
    static func hex(forLine line: String, in place: Place) -> String? {
        guard place.kind == .metroStation else { return nil }
        return MetroLine.allLines.first { $0.displayName == line }?.colorHex
    }

    /// Black or white text on `hex`, by the app's WCAG rule.
    static func textColor(on hex: String) -> Color {
        HexLuminance.isLight(hex) ? .black : .white
    }
}
