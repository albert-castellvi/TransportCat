import SwiftUI

/// SwiftUI color from a TMB hex string, with or without a leading "#".
extension Color {
    init(hex: String) {
        let components = LineColorHex.components(of: hex)
        self.init(red: components.red, green: components.green, blue: components.blue)
    }
}

/// Parse rule of the operator colour strings (`COLOR_LINIA`, line catalogs).
///
/// The bus catalog stores the raw field with an empty default, so the string is
/// validated the way `HexLuminance` validates it — six hex digits, optionally
/// after "#" — and anything else falls back to the neutral grey the app paints
/// a missing colour with. An unchecked `scanHexInt64` used to leave the value
/// at 0 and paint opaque black.
enum LineColorHex {
    /// The neutral grey of a line without a colour, the same one
    /// `FGCParsers.neutralColorHex` and the planner's route badges use.
    static let neutralHex = "8E8E93"

    /// `neutralHex` as 0...1 channels. `ColorFromHexTests` keeps the two in
    /// sync, so the string and the numbers cannot drift apart.
    static let neutral = (
        red: Double(0x8E) / 255,
        green: Double(0x8E) / 255,
        blue: Double(0x93) / 255
    )

    /// The channels of "RRGGBB" or "#RRGGBB"; nil when the string is anything
    /// else (empty, wrong length, non-hex digits).
    static func parse(_ hex: String) -> (red: Double, green: Double, blue: Double)? {
        var digits = hex
        if digits.hasPrefix("#") {
            digits.removeFirst()
        }
        // Length and digits checked first, exactly like `HexLuminance`: with a
        // longer string the channel shifts would read the wrong bytes.
        guard digits.count == 6, digits.allSatisfy(\.isHexDigit) else { return nil }
        guard let value = UInt32(digits, radix: 16) else { return nil }
        return (
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    /// The channels of a line colour; the neutral grey when the feed sent
    /// something that is not a colour.
    static func components(of hex: String) -> (red: Double, green: Double, blue: Double) {
        parse(hex) ?? neutral
    }
}
