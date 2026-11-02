import SwiftUI

/// One arrival inside the detail list: line badge, destination, countdown
/// (spec S22).
@MainActor
struct WatchArrivalRow: View {
    let arrival: NextArrival

    var body: some View {
        HStack(spacing: 6) {
            Text(arrival.line)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.2), in: Capsule())
            VStack(alignment: .leading, spacing: 1) {
                Text(arrival.destination)
                    .font(.caption)
                    .lineLimit(1)
                Text(WatchArrivalFormatting.countdown(until: arrival.date))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        let minutes = WatchArrivalFormatting.countdown(until: arrival.date)
        return "\(arrival.line) cap a \(arrival.destination), \(minutes)"
    }
}
