import SwiftUI

/// One arrival inside the detail list: line badge, destination and countdown
/// (spec S22, reviews W4, W6, W7, W8, W14).
///
/// The countdown is the largest and highest-contrast text of the row: it is what
/// the rider raised the wrist for. The line keeps its network colour when the
/// watch knows it (metro, from `MetroLine.allLines`) and a neutral badge when it
/// does not, so the colour never states something the data does not.
@MainActor
struct WatchArrivalRow: View {
    let arrival: NextArrival
    /// The line colour at the place being shown, or nil when unknown.
    let colorHex: String?
    /// The instant the countdown is drawn for; the list ticks it.
    let now: Date

    var body: some View {
        HStack(spacing: 6) {
            Text(arrival.line)
                .font(.caption2.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(badgeTextColor)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Capsule().fill(badgeColor))
                .accessibilityHidden(true)
            Text(arrival.destination)
                .font(.footnote)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 4)
            Text(countdown)
                .font(.title3.weight(.semibold).monospacedDigit())
                .foregroundStyle(isImminent ? Color(hex: WatchLineColor.imminentHex) : Color.primary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var countdown: String {
        WatchArrivalFormatting.countdown(until: arrival.date, now: now)
    }

    /// The row colour the phone gives an imminent arrival (spec S12): "ara" in
    /// green. The word is still printed, so nothing is carried by colour alone;
    /// it uses the same grace the countdown text does.
    private var isImminent: Bool {
        ArrivalBoard.isDue(arrival.date, now: now)
    }

    private var badgeColor: Color {
        guard let colorHex else { return Color.secondary.opacity(0.25) }
        return Color(hex: colorHex)
    }

    private var badgeTextColor: Color {
        guard let colorHex else { return Color.primary }
        return WatchLineColor.textColor(on: colorHex)
    }

    private var accessibilityLabel: String {
        let spoken = WatchArrivalFormatting.spokenCountdown(until: arrival.date, now: now)
        return "\(arrival.line) cap a \(arrival.destination), \(spoken)"
    }
}
