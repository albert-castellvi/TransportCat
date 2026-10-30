import SwiftUI

/// Capsule telling the rider how fresh the data on screen is (spec S7).
///
/// The age is read from the `TimelineView` clock below, so a chip that says
/// "fa 12 s" keeps counting instead of freezing at the value it had when the
/// line finished loading.
struct FreshnessChip: View {
    let lineState: LineState

    /// Dot color per freshness level (spec S7): green, amber, red, gray.
    private static let liveColor = Color.green
    private static let delayedColor = Color.orange
    private static let staleColor = Color.red
    private static let unavailableColor = Color.gray

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let status = status(now: context.date)
            HStack(spacing: 6) {
                Circle()
                    .fill(status.color)
                    .frame(width: 8, height: 8)
                Text(status.text)
                    .font(.caption2.bold())
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.thinMaterial, in: Capsule())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(status.text)
        }
    }

    /// Dot color and Catalan wording for the given clock.
    private func status(now: Date) -> (color: Color, text: String) {
        // A line TMB publishes no arrivals for is never "En directe", however
        // recent the last empty answer was (spec S8).
        if lineState.isFeedEmpty {
            return (Self.unavailableColor, "Sense dades en temps real")
        }
        switch lineState.freshness(now: now) {
        case .live:
            return (Self.liveColor, "En directe · \(age(now: now))")
        case .delayed:
            return (Self.delayedColor, "Amb retard · \(age(now: now))")
        case .stale:
            return (Self.staleColor, "Dades antigues · \(age(now: now))")
        case .unavailable:
            // No successful poll yet: there is no age to show.
            return (Self.unavailableColor, "Sense dades")
        }
    }

    /// Age of the last successful arrivals update, empty when there is none.
    private func age(now: Date) -> String {
        guard let updatedAt = lineState.arrivalsUpdatedAt else { return "" }
        return Freshness.ageText(since: updatedAt, now: now)
    }
}

/// Notice for a line with no live feed at all (spec S8).
///
/// The map draws it centered over the map, Xarxa as a block above the rows;
/// both use this view so the wording and the icon can never differ.
struct NoRealtimeDataCard: View {
    /// A one-row strip for the map, where the card must not hide the line;
    /// Xarxa keeps the centered block above its rows.
    var compact = false

    var body: some View {
        Group {
            if compact {
                HStack(spacing: 10) {
                    icon(size: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sense dades en temps real")
                            .font(.footnote.bold())
                        Text("TMB no publica les arribades d'aquesta línia.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(10)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
            } else {
                VStack(spacing: 8) {
                    icon(size: 32)
                    Text("Sense dades en temps real")
                        .font(.headline)
                        .multilineTextAlignment(.center)
                    Text("TMB no publica les arribades d'aquesta línia.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(16)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
        }
        // It is a notice, not a control: the map stays pannable under it.
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }

    private func icon(size: CGFloat) -> some View {
        Image("icon-realtime-off")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(.secondary)
    }
}
