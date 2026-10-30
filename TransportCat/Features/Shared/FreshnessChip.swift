import SwiftUI

/// Capsule telling the rider how fresh the data on screen is (spec S7).
///
/// The age is read from the `TimelineView` clock below, so a chip that says
/// "fa 12 s" keeps counting instead of freezing at the value it had when the
/// line finished loading.
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

    /// Dot color per freshness level (spec S7): green, amber, red, gray.
    private static let liveColor = Color.green
    private static let delayedColor = Color.orange
    private static let staleColor = Color.red
    private static let unavailableColor = Color.gray
    /// A line drawn from the timetable rather than a live feed (spec S7): blue,
    /// so it reads as information instead of a degraded live state.
    private static let theoreticalColor = Color.blue

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = context.date
            let lastUpdate = lineState?.arrivalsUpdatedAt ?? updatedAt
            let attemptFailed = lineState?.lastPollFailed ?? lastAttemptFailed
            let empty = lineState?.isFeedEmpty ?? feedEmpty
            let theoretical = lineState?.isTheoretical ?? false
            let status = status(now: now, lastUpdate: lastUpdate, attemptFailed: attemptFailed, feedEmpty: empty, theoretical: theoretical)
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

    /// Dot color and Catalan wording for the given clock and feed values.
    ///
    /// The level comes from `Freshness.level` exactly as the metro chip did
    /// through `LineState.freshness`, so both sources share one rule (S2, S5).
    private func status(now: Date, lastUpdate: Date?, attemptFailed: Bool, feedEmpty: Bool, theoretical: Bool) -> (color: Color, text: String) {
        // Trains computed from the timetable: the age of the schedule is not a
        // data age, so the chip says what it is and shows no countdown (S7).
        if theoretical {
            return (Self.theoreticalColor, "Horari teòric")
        }
        // A line TMB publishes no arrivals for is never "En directe", however
        // recent the last empty answer was (spec S8).
        if feedEmpty {
            return (Self.unavailableColor, "Sense dades en temps real")
        }
        let age = age(now: now, lastUpdate: lastUpdate)
        switch Freshness.level(lastUpdate: lastUpdate, now: now, lastAttemptFailed: attemptFailed) {
        case .live:
            return (Self.liveColor, "En directe · \(age)")
        case .delayed:
            return (Self.delayedColor, "Amb retard · \(age)")
        case .stale:
            return (Self.staleColor, "Dades antigues · \(age)")
        case .unavailable:
            // No successful poll yet: there is no age to show.
            return (Self.unavailableColor, "Sense dades")
        }
    }

    /// Age of the last successful arrivals update, empty when there is none.
    private func age(now: Date, lastUpdate: Date?) -> String {
        guard let lastUpdate else { return "" }
        return Freshness.ageText(since: lastUpdate, now: now)
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
