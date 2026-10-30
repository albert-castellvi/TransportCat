import SwiftUI

/// Badge of a bus line: the TMB-style rounded rectangle in the line's own
/// colors (spec S2).
///
/// Metro badges are pre-rendered images because the eleven line colors are
/// fixed; the bus catalog has 115 lines whose colors arrive as hex strings, so
/// the badge is drawn here from `COLOR_LINIA` and `COLOR_TEXT_LINIA`.
struct BusBadge: View {
    let line: BusLine
    /// Width in points; the height follows the prototype's badge ratio.
    var width: CGFloat = 52

    /// Height as a fraction of the width, as drawn in the prototype.
    private static let heightRatio: CGFloat = 0.58
    private static let cornerRadius: CGFloat = 9

    var body: some View {
        RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
            .fill(Color(hex: line.colorHex))
            .frame(width: width, height: width * Self.heightRatio)
            .overlay {
                RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                    .stroke(.white, lineWidth: 2)
            }
            .overlay {
                Text(line.name)
                    .font(.system(size: fontSize, weight: .bold))
                    .foregroundStyle(Color(hex: line.textColorHex))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(.horizontal, 4)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Línia \(line.name)")
    }

    /// Letter size scaled with the badge, so the same view works at the map,
    /// picker and row sizes; long names ("Convencional de barri"...) shrink via
    /// `minimumScaleFactor` instead of being clipped.
    private var fontSize: CGFloat {
        max(9, min(width * 0.3, 22))
    }
}
