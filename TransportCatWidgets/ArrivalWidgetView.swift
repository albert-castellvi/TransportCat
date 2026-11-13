import AppIntents
import SwiftUI
import WidgetKit

/// The layouts of the "Properes arribades" widget (spec S20): one board per
/// place on the home screen, the first place on the lock screen.
struct ArrivalWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode
    /// The badge glyph is drawn at a fixed size today; scaling it keeps the
    /// line code, which identifies the row, readable at larger text sizes.
    @ScaledMetric(relativeTo: .caption2) private var compactBadgeSize: CGFloat = 8
    @ScaledMetric(relativeTo: .caption) private var badgeSize: CGFloat = 11

    let entry: ArrivalEntry

    var body: some View {
        Group {
            if family == .accessoryRectangular {
                accessoryRectangular
            } else {
                home
                    // One tap anywhere outside a row or a place name opens the
                    // first place (F4). Per-row `Link`s take precedence.
                    .widgetURL(boards.first.flatMap { DeepLink.url(for: $0.place) })
            }
        }
        // The four layouts are drawn for the default range and clamp above it,
        // so a row can never push the footer off the widget.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
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

    /// Full-width rows have room for the following arrival.
    private var isWide: Bool {
        family != .systemSmall && !inColumns
    }

    /// The snapshot is older than two reloads, so the rows are gone because
    /// the data aged, not because nothing is coming (F1). Never render "Sense
    /// arribades" in this state.
    private var isStale: Bool {
        ArrivalBoard.isStale(fetched: entry.fetched, at: entry.date)
    }

    /// "ara mateix", "fa 2 min", "fa 1 h" — the app's own wording.
    private var ageText: String {
        Freshness.ageText(since: entry.fetched, now: entry.date)
    }

    private var rowsPerBoard: Int {
        switch family {
        case .systemLarge: return max(2, 10 / max(boards.count, 1) - 1)
        // Three rows plus the 44 pt footer fit the medium height.
        default: return 3
        }
    }

    private func rows(of board: PlaceBoard, limit: Int) -> [ArrivalBoardRow] {
        ArrivalBoard.rows(board.arrivals ?? [], fetched: entry.fetched, at: entry.date, limit: limit)
    }

    // MARK: - Home-screen families

    private var home: some View {
        Group {
            if boards.isEmpty {
                needsPlace
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    if inColumns {
                        HStack(alignment: .top, spacing: 14) {
                            ForEach(Array(boards.enumerated()), id: \.offset) { _, board in
                                boardView(board)
                            }
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(boards.enumerated()), id: \.offset) { _, board in
                                boardView(board)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                    footer
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        // The canvas is navy in every appearance (see `background`), so the
        // content resolves its semantic colours for a dark surface instead of
        // being overridden by a light tint (F17).
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }

    /// Shown before a place is chosen and there is no favourite to stand in.
    private var needsPlace: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("TransportCat")
                .font(.caption.weight(.semibold))
                .opacity(0.75)
            Spacer(minLength: 0)
            Text("Tria un lloc")
                .font(.headline)
            Text("Mantén premut el widget per editar-lo.")
                .font(.caption2)
                .opacity(0.7)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func boardView(_ board: PlaceBoard) -> some View {
        let shown = rows(of: board, limit: rowsPerBoard)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                placeNameLink(board)
                Spacer(minLength: 0)
            }
            if isStale {
                // The footer carries the age and the refresh; a board with no
                // honest rows keeps only its name.
                EmptyView()
            } else if board.arrivals == nil {
                notice("No s'ha pogut connectar")
            } else if shown.isEmpty {
                notice("Sense arribades")
            } else {
                ForEach(shown, id: \.self) { row in
                    rowLink(row, board: board)
                }
            }
        }
        // Natural height: the footer owns the leftover space, so the rows stay
        // under the place name instead of floating in the middle.
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func notice(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .lineLimit(2)
            .minimumScaleFactor(0.85)
            .opacity(0.7)
    }

    /// The place name doubles as the tap target of its board, so a column's
    /// own place opens and not only the first one.
    @ViewBuilder
    private func placeNameLink(_ board: PlaceBoard) -> some View {
        let name = Text(board.name)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .opacity(0.75)
        if let url = DeepLink.url(for: board.place) {
            Link(destination: url) { name }
        } else {
            name
        }
    }

    @ViewBuilder
    private func rowLink(_ row: ArrivalBoardRow, board: PlaceBoard) -> some View {
        if let url = DeepLink.url(for: board.place) {
            Link(destination: url) { rowView(row) }
        } else {
            rowView(row)
        }
    }

    /// Data age and the widget's one control. Every family says how fresh the
    /// data is, and when it is too old the line becomes the reason the rows
    /// are missing (F1).
    private var footer: some View {
        HStack(alignment: .center, spacing: 6) {
            Text(ageLabel)
                .font(.caption2)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .opacity(isStale ? 0.95 : 0.6)
                .accessibilityLabel(ageSpokenLabel)
            Spacer(minLength: 0)
            reloadButton
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var ageLabel: String {
        if isStale { return "Dades de \(ageText)" }
        // The small family has no room for the word, and the refresh icon sits
        // beside it.
        return family == .systemSmall ? ageText : "Actualitzat \(ageText)"
    }

    private var ageSpokenLabel: String {
        isStale ? "Dades de \(ageText). Actualitza-les." : "Dades actualitzades \(ageText)."
    }

    /// Asks for fresh arrivals with a full 44 pt target: the glyph stays small
    /// so it does not shout, the touchable area does not (F4).
    private var reloadButton: some View {
        Button(intent: ReloadArrivalsIntent()) {
            Image(systemName: "arrow.clockwise")
                .font(.caption.weight(.semibold))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Actualitza les arribades")
    }

    private func rowView(_ row: ArrivalBoardRow) -> some View {
        HStack(spacing: 6) {
            lineBadge(row.line, compact: false)
            // The direction is what the rider matches against the platform
            // sign, so it keeps its width before the numbers do (F7).
            Text(row.destination)
                .font(.caption)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .layoutPriority(1)
                .opacity(0.9)
            Spacer(minLength: 2)
            countdown(row.next, font: .system(.subheadline, design: .rounded).weight(.bold))
                .frame(minWidth: 34, alignment: .trailing)
            if isWide {
                Text(row.following.map { "· " + ArrivalBoard.minutesText(until: $0, now: entry.date) } ?? "")
                    .font(.caption2)
                    .lineLimit(1)
                    .opacity(0.6)
                    .frame(minWidth: 40, alignment: .leading)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(ArrivalBoard.spokenRow(row, now: entry.date))
    }

    // MARK: - Lock-screen family

    private var accessoryRectangular: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let board = boards.first {
                Text(board.name)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .widgetAccentable()
                    // A station name on a locked phone says where its owner is.
                    .privacySensitive()
                if isStale {
                    notice("Dades de \(ageText)")
                } else if board.arrivals == nil {
                    notice("Sense connexió")
                } else {
                    let shown = rows(of: board, limit: 2)
                    if shown.isEmpty {
                        notice("Sense arribades")
                    }
                    ForEach(shown, id: \.self) { row in
                        HStack(spacing: 5) {
                            lineBadge(row.line, compact: true)
                            Text(row.destination)
                                .font(.caption2)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            countdown(row.next, font: .caption2.weight(.semibold))
                                .frame(minWidth: 34, alignment: .trailing)
                        }
                        // One element per arrival: the countdown alone is
                        // read as a raw interval and updates on its own.
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(ArrivalBoard.spokenRow(row, now: entry.date))
                    }
                }
            } else {
                Text("Tria un lloc")
                    .font(.caption2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Shared pieces

    /// Countdown of one arrival, in the app's words: "ara" or "N min". The
    /// timeline advances a row every 30 s, so the text is never frozen at
    /// fetch time; it is never seconds either, which no other surface speaks
    /// and the feed does not measure (F5).
    private func countdown(_ date: Date, font: Font) -> some View {
        Text(ArrivalBoard.minutesText(until: date, now: entry.date))
            .font(font.monospacedDigit())
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .multilineTextAlignment(.trailing)
    }

    /// Line code on its brand color, the same badge the app draws.
    private func lineBadge(_ line: String, compact: Bool) -> some View {
        let hex = ArrivalWidgetStyle.colorHex(for: line)
        return Text(line)
            .font(.system(size: compact ? compactBadgeSize : badgeSize, weight: .bold))
            .foregroundStyle(badgeGlyphColor(hex))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, compact ? 3 : 5)
            .padding(.vertical, compact ? 1 : 2)
            .frame(minWidth: compact ? 0 : 28)
            .background { badgeBackground(hex) }
            .widgetAccentable(renderingMode == .accented)
    }

    /// Accented rendering keeps only two tones: the accent group (views marked
    /// `widgetAccentable`) and the default group. A capsule filled with the
    /// brand colour would therefore be repainted while the glyph kept the
    /// black or white chosen for that brand colour. The badge keeps the code
    /// in the accent group over a neutral capsule, the one pairing the system
    /// keeps legible (F17).
    @ViewBuilder
    private func badgeBackground(_ hex: String) -> some View {
        if renderingMode == .accented {
            Capsule().fill(.quaternary)
        } else {
            Capsule().fill(Color(hex: hex))
        }
    }

    private func badgeGlyphColor(_ hex: String) -> Color {
        if renderingMode == .accented { return .primary }
        return Color(hex: HexLuminance.isLight(hex) ? "000000" : "FFFFFF")
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
}
