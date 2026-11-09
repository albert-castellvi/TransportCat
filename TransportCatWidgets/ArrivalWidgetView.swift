import SwiftUI
import WidgetKit

/// The three layouts of the "Properes arribades" widget (spec S20).
struct ArrivalWidgetView: View {
    @Environment(\.widgetFamily) private var family

    let entry: ArrivalEntry

    var body: some View {
        Group {
            switch family {
            case .accessoryRectangular:
                accessoryRectangular
            case .systemMedium:
                medium
            default:
                small
            }
        }
        .containerBackground(for: .widget) { background }
    }

    // MARK: - Home-screen families

    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if let message = emptyMessage {
                Spacer(minLength: 0)
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 0)
            } else {
                ForEach(Array(entry.arrivals.prefix(2).enumerated()), id: \.offset) { _, arrival in
                    row(arrival, showsDestination: true)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var medium: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if let message = emptyMessage {
                Spacer(minLength: 0)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else {
                ForEach(Array(entry.arrivals.prefix(3).enumerated()), id: \.offset) { _, arrival in
                    row(arrival, showsDestination: true)
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Lock-screen family

    private var accessoryRectangular: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let name = entry.placeName {
                Text(name)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .widgetAccentable()
            }
            if let message = emptyMessage {
                Text(message)
                    .font(.caption2)
                    .lineLimit(2)
            } else if let arrival = entry.arrivals.first {
                HStack(spacing: 5) {
                    lineBadge(arrival, compact: true)
                    Text(arrival.destination)
                        .font(.caption2)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    countdown(arrival, font: .caption2.weight(.semibold))
                }
                ForEach(Array(entry.arrivals.dropFirst().prefix(1).enumerated()), id: \.offset) { _, next in
                    HStack(spacing: 5) {
                        lineBadge(next, compact: true)
                        Text(next.destination)
                            .font(.caption2)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        countdown(next, font: .caption2)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Shared pieces

    /// Station or stop name, the same on every family.
    private var header: some View {
        Text(entry.placeName ?? "TransportCat")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    /// "Tria una estació" until a place is configured, "Sense arribades" when
    /// the feed answers with nothing (spec S20).
    private var emptyMessage: String? {
        guard entry.hasPlace else { return "Tria una estació" }
        return entry.arrivals.isEmpty ? "Sense arribades" : nil
    }

    private func row(_ arrival: NextArrival, showsDestination: Bool) -> some View {
        HStack(spacing: 6) {
            lineBadge(arrival, compact: false)
            if showsDestination {
                Text(arrival.destination)
                    .font(.caption)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            countdown(arrival, font: .caption.weight(.semibold))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Línia \(arrival.line) cap a \(arrival.destination), "
                + ArrivalWidgetStyle.minutesText(until: arrival.date, now: Date())
        )
    }

    /// Countdown of one arrival, from the wall clock instead of the entry date.
    ///
    /// `Text(timerInterval:)` is a self-updating text: the widget keeps counting
    /// down between reloads, which WidgetKit only grants within its own budget,
    /// so the number is never frozen at fetch time (bug #30). An arrival that
    /// the last fetch already saw as due (or that an old entry renders as past)
    /// reads "ara", the same word `ArrivalWidgetStyle.minutesText` uses.
    @ViewBuilder
    private func countdown(_ arrival: NextArrival, font: Font) -> some View {
        if ArrivalWidgetStyle.isDue(arrival.date) {
            Text("ara")
                .font(font.monospacedDigit())
        } else {
            Text(timerInterval: Date.now...arrival.date, countsDown: true)
                .font(font.monospacedDigit())
        }
    }

    /// Line code on its brand color, the same badge the app draws.
    private func lineBadge(_ arrival: NextArrival, compact: Bool) -> some View {
        let hex = ArrivalWidgetStyle.colorHex(for: arrival.line)
        return Text(arrival.line)
            .font(.system(size: compact ? 8 : 9, weight: .bold))
            .foregroundStyle(Color(hex: HexLuminance.isLight(hex) ? "000000" : "FFFFFF"))
            .padding(.horizontal, compact ? 3 : 4)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color(hex: hex)))
            .lineLimit(1)
    }

    /// The widget background. The lock-screen family draws on the system
    /// material, so it asks for a clear background.
    private var background: Color {
        family == .accessoryRectangular ? .clear : Color(hex: "0B1220")
    }
}

/// Pure presentation helpers of the widget (spec S20).
enum ArrivalWidgetStyle {
    /// Brand color of a display line code: metro lines have one, everything
    /// else (bus, FGC) gets a neutral tile because the catalog is not in the
    /// widget.
    static func colorHex(for line: String) -> String {
        MetroLine.allLines
            .first { $0.displayName == line || $0.code == line }?
            .colorHex ?? "6B7280"
    }

    /// Whether an arrival is due: the 30-second grace the countdown reads
    /// "ara" for, shared by the static text and the self-updating timer.
    static func isDue(_ date: Date, now: Date = Date()) -> Bool {
        date.timeIntervalSince(now) <= 30
    }

    /// "<1 min", "2 min" or "ara" for an arrival, never a negative countdown.
    /// The widget prints a self-updating timer instead; this is the text of the
    /// accessibility label and the spoken form.
    static func minutesText(until date: Date, now: Date) -> String {
        if isDue(date, now: now) { return "ara" }
        return "\(Int(ceil(date.timeIntervalSince(now) / 60))) min"
    }
}
