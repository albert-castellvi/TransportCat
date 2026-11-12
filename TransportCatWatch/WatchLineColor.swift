import SwiftUI

/// Line colours and the imminent green on the wrist (review W6, W4).
///
/// `Core/ColorFromHex.swift` and `Core/HexLuminance.swift` are not compiled
/// into the watch target, so the parse, the WCAG relative luminance and the
/// 0.179 light threshold are repeated here with the same behaviour. Delete them
/// from here and use the shared files once they are added to the target.
///
/// Metro lines carry their brand colour in `MetroLine.allLines`, which the
/// watch already compiles. Bus and FGC colours come from feeds the watch does
/// not load, so those badges stay neutral instead of guessing.
enum WatchLineColor {
    /// The grey of a line with no known colour, the same one the app paints a
    /// line without a colour with.
    static let neutralHex = "8E8E93"

    /// The colour the phone paints an imminent arrival with (spec S12).
    static let imminentHex = "30D158"

    /// Colours above this relative luminance need black text: 0.179 is where
    /// the WCAG contrast of black text equals that of white text.
    static let lightThreshold = 0.179

    /// The line colour of `line` at `place`, or nil when the watch has no
    /// source for it.
    ///
    /// Only metro is answered from local data. A bus or FGC line would need its
    /// catalog fetched, which the watch does not do for a badge.
    static func hex(forLine line: String, in place: Place) -> String? {
        guard place.kind == .metroStation else { return nil }
        return MetroLine.allLines.first { $0.displayName == line }?.colorHex
    }

    /// SwiftUI colour of a "RRGGBB" or "#RRGGBB" string; neutral grey when the
    /// string is anything else.
    static func color(_ hex: String) -> Color {
        let channels = components(of: hex)
            ?? components(of: neutralHex)
            ?? (red: 0.56, green: 0.56, blue: 0.58)
        return Color(red: channels.red, green: channels.green, blue: channels.blue)
    }

    /// Black or white text on `hex`, whichever the fill can carry.
    static func textColor(on hex: String) -> Color {
        guard let channels = components(of: hex) else { return .white }
        return luminance(of: channels) > lightThreshold ? .black : .white
    }

    // MARK: - WCAG

    private static func luminance(of color: (red: Double, green: Double, blue: Double)) -> Double {
        func linearize(_ channel: Double) -> Double {
            channel <= 0.03928
                ? channel / 12.92
                : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linearize(color.red)
            + 0.7152 * linearize(color.green)
            + 0.0722 * linearize(color.blue)
    }

    private static func components(of hex: String) -> (red: Double, green: Double, blue: Double)? {
        var digits = hex
        if digits.hasPrefix("#") {
            digits.removeFirst()
        }
        // Length and digits checked first: a longer string would otherwise read
        // the wrong bytes through the channel shifts.
        guard digits.count == 6, digits.allSatisfy(\.isHexDigit) else { return nil }
        guard let value = UInt32(digits, radix: 16) else { return nil }
        return (
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
