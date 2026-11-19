import SwiftUI

/// The trip's lines as one compact badge row (spec S4): one pill per ride in
/// the colors the planner published, joined by small chevrons, so a trip reads
/// as "L1 › S2" at a glance. Walk legs are not shown: the badges carry the
/// rides only, exactly as `SavedTrip` stores them.
struct TripLineBadges: View {
    let legs: [SavedTripLeg]

    /// Neutral fill for a line the feed published without a color.
    private static let fallbackColorHex = "8E8E93"

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(legs.enumerated()), id: \.offset) { index, leg in
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                ExploreLineBadge(
                    label: leg.lineName,
                    colorHex: leg.colorHex ?? Self.fallbackColorHex,
                    textColorHex: leg.textColorHex
                )
            }
        }
        // One element for the whole row: "Línies L1, S2", instead of one
        // "Línia …" per badge.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Línies \(legs.map(\.lineName).joined(separator: ", "))")
    }
}
