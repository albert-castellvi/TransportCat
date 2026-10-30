import Foundation

/// Whether a TMB line colour is light enough to need dark text on top (spec S6).
///
/// The arrival pills are filled with the line colour, so the text colour has to
/// follow the fill: black on a light colour, white otherwise. The decision uses
/// the sRGB relative luminance from WCAG, without SwiftUI, so it is testable
/// without a UI.
enum HexLuminance {
    /// Colours above this relative luminance count as light. 0.179 is where the
    /// WCAG contrast of black text equals that of white text, so each side of
    /// it picks the more readable of the two (a 0.5 cut left every TMB colour,
    /// yellow and orange included, on white text).
    static let lightThreshold = 0.179

    /// `true` when text drawn on `hex` must be black.
    ///
    /// Accepts an optional leading "#" and exactly six hex digits, the shape of
    /// `MetroLine.colorHex`. Anything else is not a colour we can judge, and
    /// falls back to the white-text answer.
    static func isLight(_ hex: String) -> Bool {
        guard let color = components(of: hex) else { return false }
        return luminance(of: color) > lightThreshold
    }

    /// Relative luminance of a 0...1 sRGB triple, as defined by WCAG 2.x:
    /// linearize each channel, then weight red, green and blue by eye
    /// sensitivity (0.2126, 0.7152, 0.0722).
    static func luminance(of color: (red: Double, green: Double, blue: Double)) -> Double {
        0.2126 * linearize(color.red)
            + 0.7152 * linearize(color.green)
            + 0.0722 * linearize(color.blue)
    }

    /// sRGB gamma expansion: the piecewise curve from the sRGB specification,
    /// linear below the 0.03928 offset and a power curve above it.
    private static func linearize(_ channel: Double) -> Double {
        channel <= 0.03928
            ? channel / 12.92
            : pow((channel + 0.055) / 1.055, 2.4)
    }

    /// Parses "#RRGGBB" or "RRGGBB" into 0...1 channels.
    private static func components(of hex: String) -> (red: Double, green: Double, blue: Double)? {
        var digits = hex
        if digits.hasPrefix("#") {
            digits.removeFirst()
        }
        // Length and digits checked first: `UInt32(_:radix:)` would otherwise
        // sign-extend or parse a shorter string as a different colour.
        guard digits.count == 6, digits.allSatisfy(\.isHexDigit) else { return nil }
        guard let value = UInt32(digits, radix: 16) else { return nil }
        return (
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
