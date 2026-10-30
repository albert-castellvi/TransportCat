import SwiftUI

/// The line selector of the bus screens (spec S2): a card showing the selected
/// line — badge, ends and headline — that opens the catalog sheet when tapped.
///
/// With no line selected yet (the catalog is still loading) it asks the rider
/// to choose one, so the header never shows an empty row.
struct BusLineButton: View {
    let line: BusLine?
    let action: () -> Void

    /// Height of the card, as drawn in the prototype's line selector.
    private static let height: CGFloat = 56
    private static let cornerRadius: CGFloat = 14
    private static let badgeWidth: CGFloat = 46

    init(line: BusLine?, action: @escaping () -> Void) {
        self.line = line
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if let line {
                    BusBadge(line: line, width: Self.badgeWidth)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(line.origin)  ⇄  \(line.destination)")
                            .font(.system(size: 15, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Text(line.description)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                } else {
                    Text("Tria una línia")
                        .font(.system(size: 15, weight: .semibold))
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .frame(height: Self.height)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                    .fill(Color(white: 0.11))
            )
            .contentShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(line.map { "Línia \($0.name), \($0.origin) a \($0.destination)" } ?? "Tria una línia")
    }
}
