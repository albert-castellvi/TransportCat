import SwiftUI

/// SwiftUI color from a TMB hex string (no leading "#").
extension Color {
    init(hex: String) {
        var value: UInt64 = 0
        var characters = hex
        if characters.hasPrefix("#") {
            characters.removeFirst()
        }
        Scanner(string: characters).scanHexInt64(&value)
        self.init(
            red: Double((value >> 16) & 0xFF) / 255.0,
            green: Double((value >> 8) & 0xFF) / 255.0,
            blue: Double(value & 0xFF) / 255.0
        )
    }
}
