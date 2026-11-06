import SwiftUI

/// Glass status capsule over the map and the screens, top-left in the v2
/// chrome (redesign spec S2): how fresh the data on screen is, and — while the
/// device has no network path — that what is drawn comes from saved data and
/// the theoretical timetable (the wording of the offline banner this capsule
/// absorbs).
///
/// The state decision lives in the pure `StatusCapsuleState` helper, tested
/// without a UI; this view only renders it. The age is read from the
/// `TimelineView` clock below, so a capsule that says "fa 12 s" keeps counting
/// instead of freezing at the value it had when the line finished loading.
///
/// Both initializers keep their exact signatures: the metro screen passes its
/// `LineState`, and the bus, FGC, global and Parades screens pass the values
/// of their own poll cycle.
struct FreshnessChip: View {
    /// Metro source, nil for the explicit bus source below. Both feed the same
    /// rendering; only where the timestamps come from differs.
    private let lineState: LineState?
    /// Explicit source (bus screens, spec S3): the values of a poll cycle
    /// without a `LineState` behind them.
    private let updatedAt: Date?
    private let lastAttemptFailed: Bool
    private let feedEmpty: Bool

    init(lineState: LineState) {
        self.lineState = lineState
        self.updatedAt = nil
        self.lastAttemptFailed = false
        self.feedEmpty = false
    }

    /// Chip for a feed that is not a metro `LineState`: the bus screens pass
    /// the values of their own poll cycle (spec S3, S5).
    ///
    /// - `feedEmpty`: the line answers but publishes no arrivals at all, which
    ///   is reported instead of a countdown age.
    init(updatedAt: Date?, lastAttemptFailed: Bool, feedEmpty: Bool = false) {
        self.lineState = nil
        self.updatedAt = updatedAt
        self.lastAttemptFailed = lastAttemptFailed
        self.feedEmpty = feedEmpty
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let lastUpdate = lineState?.arrivalsUpdatedAt ?? updatedAt
            let attemptFailed = lineState?.lastPollFailed ?? lastAttemptFailed
            let empty = lineState?.isFeedEmpty ?? feedEmpty
            let theoretical = lineState?.isTheoretical ?? false
            let status = StatusCapsule.make(
                isOnline: ConnectivityMonitor.shared.isOnline,
                updatedAt: lastUpdate,
                lastAttemptFailed: attemptFailed,
                feedEmpty: empty,
                theoretical: theoretical,
                now: context.date
            )
            HStack(spacing: 7) {
                statusIcon(of: status)
                    .font(.system(size: 11, weight: .semibold))
                Text(status.label)
                    .font(.caption.weight(.semibold))
                if !status.detail.isEmpty {
                    Text(status.detail)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .glassEffect()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(a11yLabel(of: status))
        }
    }

    /// The status dot in its level color, or the wifi-off symbol offline.
    @ViewBuilder
    private func statusIcon(of status: StatusCapsuleState) -> some View {
        switch status.icon {
        case .wifiOff:
            Image(systemName: "wifi.slash")
                .foregroundStyle(Color(hex: "FF9F0A"))
        case .dot(let kind):
            Circle()
                .fill(Self.dotColor(kind))
                .frame(width: 8, height: 8)
        }
    }

    /// Dot color per level, the palette the chip has always used: green,
    /// amber, red, gray, and blue for the theoretical level.
    private static func dotColor(_ kind: StatusDotKind) -> Color {
        switch kind {
        case .live: return .green
        case .delayed: return .orange
        case .stale: return .red
        case .unavailable: return .gray
        case .theoretical: return .blue
        }
    }

    /// One combined VoiceOver label, so the parts are never read apart.
    private func a11yLabel(of status: StatusCapsuleState) -> String {
        status.detail.isEmpty ? status.label : "\(status.label), \(status.detail)"
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
    /// The line has no live feed but the bundled timetable fills it in: the
    /// second line says what is shown instead (spec S7).
    var theoretical = false

    var body: some View {
        Group {
            if compact {
                HStack(spacing: 10) {
                    icon(size: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sense dades en temps real")
                            .font(.footnote.bold())
                        Text(secondLine)
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
                    Text(secondLine)
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

    /// Explanation under the title, shared by the compact and the full style so
    /// the two can never say different things (S7).
    private var secondLine: String {
        theoretical
            ? "Es mostra l'horari teòric."
            : "TMB no publica les arribades d'aquesta línia."
    }

    private func icon(size: CGFloat) -> some View {
        Image("icon-realtime-off")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(.secondary)
    }
}
