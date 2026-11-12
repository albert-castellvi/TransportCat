import AppIntents
import SwiftUI
import WidgetKit

/// The layouts of the "Properes arribades" widget (spec S20): one board per
/// place on the home screen, the first place on the lock screen.
struct ArrivalWidgetView: View {
    @Environment(\.widgetFamily) private var family

    let entry: ArrivalEntry

    var body: some View {
        Group {
            if family == .accessoryRectangular {
                accessoryRectangular
            } else {
                home
            }
        }
        .containerBackground(for: .widget) { background }
    }

    // MARK: - Layout rules

    private var boards: [PlaceBoard] {
        Array(entry.boards.prefix(ArrivalTimelineProvider.maxPlaces(for: family)))
    }

    /// Two places on the medium size sit side by side.
    private var inColumns: Bool {
        family == .systemMedium && boards.count > 1
    }

    /// Full-width rows have room for the following arrival and the fetch time.
    private var isWide: Bool {
        family != .systemSmall && !inColumns
    }

    private var rowsPerBoard: Int {
        switch family {
        case .systemLarge: return max(2, 10 / max(boards.count, 1) - 1)
        case .systemMedium: return inColumns ? 3 : 4
        default: return 3
        }
    }

    private func rows(of board: PlaceBoard, limit: Int) -> [ArrivalBoardRow] {
        ArrivalBoard.rows(board.arrivals, fetched: entry.fetched, at: entry.date, limit: limit)
    }

    // MARK: - Home-screen families

    private var home: some View {
        Group {
            if boards.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("TransportCat")
                        .font(.caption.weight(.semibold))
                        .opacity(0.75)
                    Spacer(minLength: 0)
                    Text("Tria una estació")
                        .font(.headline)
                    Text("Mantén premut el widget per editar-lo.")
                        .font(.caption2)
                        .opacity(0.7)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            } else if inColumns {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(Array(boards.enumerated()), id: \.offset) { index, board in
                        boardView(board, showsReload: index == boards.count - 1)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(boards.enumerated()), id: \.offset) { index, board in
                        boardView(board, showsReload: index == 0)
                    }
                }
            }
        }
        .foregroundStyle(.white)
    }

    private func boardView(_ board: PlaceBoard, showsReload: Bool) -> some View {
        let shown = rows(of: board, limit: rowsPerBoard)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text(board.name)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .opacity(0.75)
                Spacer(minLength: 0)
                if showsReload { reloadButton }
            }
            if shown.isEmpty {
                Text("Sense arribades")
                    .font(.caption2)
                    .opacity(0.6)
            } else {
                ForEach(shown, id: \.self) { row in
                    rowView(row)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Asks for fresh arrivals; the wide layouts also say when the data is from.
    private var reloadButton: some View {
        Button(intent: ReloadArrivalsIntent()) {
            HStack(spacing: 3) {
                if isWide {
                    Text(entry.fetched, style: .time)
                }
                Image(systemName: "arrow.clockwise")
            }
            .font(.caption2.weight(.semibold))
            .opacity(0.7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Actualitza")
    }

    private func rowView(_ row: ArrivalBoardRow) -> some View {
        HStack(spacing: 6) {
            lineBadge(row.line, compact: false)
            Text(row.destination)
                .font(.caption)
                .lineLimit(1)
                .opacity(0.9)
            Spacer(minLength: 2)
            countdown(row.next, font: .system(.subheadline, design: .rounded).weight(.bold))
                .frame(width: 46, alignment: .trailing)
            if isWide {
                Text(row.following.map { "· " + ArrivalWidgetStyle.minutesText(until: $0, now: entry.date) } ?? "")
                    .font(.caption2)
                    .lineLimit(1)
                    .opacity(0.6)
                    .frame(width: 52, alignment: .leading)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Línia \(row.line) cap a \(row.destination), "
                + ArrivalWidgetStyle.minutesText(until: row.next, now: entry.date)
        )
    }

    // MARK: - Lock-screen family

    private var accessoryRectangular: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let board = boards.first {
                let shown = rows(of: board, limit: 2)
                Text(board.name)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .widgetAccentable()
                if shown.isEmpty {
                    Text("Sense arribades")
                        .font(.caption2)
                }
                ForEach(shown, id: \.self) { row in
                    HStack(spacing: 5) {
                        lineBadge(row.line, compact: true)
                        Text(row.destination)
                            .font(.caption2)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        countdown(row.next, font: .caption2.weight(.semibold))
                            .frame(width: 38, alignment: .trailing)
                    }
                }
            } else {
                Text("Tria una estació")
                    .font(.caption2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Shared pieces

    /// Countdown of one arrival, from the wall clock.
    ///
    /// `Text(timerInterval:)` is a self-updating text, so the number is never
    /// frozen at fetch time (bug #30). WidgetKit renders an entry ahead of its
    /// date, so "due" is judged against the entry date, not the render clock.
    @ViewBuilder
    private func countdown(_ date: Date, font: Font) -> some View {
        if ArrivalWidgetStyle.isDue(date, now: entry.date) {
            Text("ara")
                .font(font)
        } else {
            Text(timerInterval: entry.date...date, countsDown: true)
                .font(font.monospacedDigit())
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    /// Line code on its brand color, the same badge the app draws.
    private func lineBadge(_ line: String, compact: Bool) -> some View {
        let hex = ArrivalWidgetStyle.colorHex(for: line)
        return Text(line)
            .font(.system(size: compact ? 8 : 11, weight: .bold))
            .foregroundStyle(Color(hex: HexLuminance.isLight(hex) ? "000000" : "FFFFFF"))
            .lineLimit(1)
            .padding(.horizontal, compact ? 3 : 5)
            .padding(.vertical, compact ? 1 : 2)
            .frame(minWidth: compact ? 0 : 28)
            .background(Capsule().fill(Color(hex: hex)).widgetAccentable())
    }

    // MARK: - Background

    private static let glowCenters: [UnitPoint] = [.topLeading, .bottomTrailing, .topTrailing, .bottomLeading]

    /// Colors of the lines on screen, so the backdrop follows the widget's own
    /// places; the icon palette when none of them has a brand color.
    private var glowHexes: [String] {
        var hexes: [String] = []
        for board in boards {
            for row in rows(of: board, limit: rowsPerBoard) {
                let hex = ArrivalWidgetStyle.colorHex(for: row.line)
                if hex != ArrivalWidgetStyle.neutralHex, !hexes.contains(hex) {
                    hexes.append(hex)
                }
            }
        }
        return hexes.isEmpty
            ? Array(NetworkArtGeometry.lineHexes.prefix(3))
            : Array(hexes.prefix(Self.glowCenters.count))
    }

    /// The app's dark canvas with a soft glow per line and the network motif
    /// faint on top. The lock-screen family draws on the system material, and
    /// the tinted and clear home-screen styles drop this view by themselves.
    @ViewBuilder
    private var background: some View {
        if family == .accessoryRectangular {
            Color.clear
        } else {
            ZStack {
                Color(hex: "0B1220")
                GeometryReader { geometry in
                    let radius = max(geometry.size.width, geometry.size.height) * 0.7
                    ZStack {
                        ForEach(Array(glowHexes.enumerated()), id: \.offset) { index, hex in
                            RadialGradient(
                                colors: [Color(hex: hex).opacity(0.5), Color(hex: hex).opacity(0)],
                                center: Self.glowCenters[index],
                                startRadius: 0,
                                endRadius: radius
                            )
                        }
                    }
                }
                NetworkArt(.illustration)
                    .aspectRatio(
                        NetworkArtGeometry.designWidth / NetworkArtGeometry.designHeight,
                        contentMode: .fill
                    )
                    .opacity(0.14)
                    .blur(radius: 1)
                LinearGradient(
                    colors: [.black.opacity(0), .black.opacity(0.3)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .environment(\.colorScheme, .dark)
        }
    }
}

/// Pure presentation helpers of the widget (spec S20).
enum ArrivalWidgetStyle {
    /// Tile of a line the widget has no brand color for (FGC, unknown buses).
    static let neutralHex = "6B7280"

    /// Brand color of a display line code. Metro lines carry their own.
    static func colorHex(for line: String) -> String {
        if let metro = MetroLine.allLines.first(where: { $0.displayName == line || $0.code == line }) {
            return metro.colorHex
        }
        // ponytail: bus color by network family, not the catalog's
        // COLOR_LINIA; share the bus catalog with the widget if one is wrong.
        if Int(line) != nil { return "D8232A" }
        guard line.count > 1, line.dropFirst().allSatisfy(\.isNumber) else { return neutralHex }
        switch line.first {
        case "H": return "1F4E9E"
        case "V": return "6FA53A"
        case "D": return "8E3A97"
        default: return neutralHex
        }
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
