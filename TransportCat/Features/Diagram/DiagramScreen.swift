import SwiftUI

extension IncidentKind {
    /// Asset catalog name of the icon that identifies an incident kind in the
    /// Xarxa diagram and in the station detail (S4, S7). Shared by both views
    /// so the icon of a kind never differs between them.
    var incidentIconAssetName: String {
        switch self {
        case .escalator: return "icon-escalator"
        case .elevator: return "icon-elevator"
        case .accessClosed: return "icon-entrance"
        case .stopClosed, .detour: return "icon-alert"
        case .other: return "icon-alert"
        }
    }
}

/// Vertical schematic of one line (like andana's interactive diagram):
/// stations as rows on a colored spine, live trains drawn on that spine at
/// their continuous position, station incidents inside the row, and the next
/// arrivals per station as pills.
struct DiagramScreen: View {
    @EnvironmentObject private var app: AppModel
    @State private var selectedLineCode = MetroLine.allLines[0].code
    @State private var lineState: LineState?
    @State private var selectedStation: Station?

    private var selectedLine: MetroLine {
        MetroLine.line(forCode: selectedLineCode) ?? MetroLine.allLines[0]
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ModeSelector()
                    .padding(.horizontal, 16)
                LinePicker(selectedLineCode: $selectedLineCode)
                chipsRow
                content
            }
            .navigationTitle("Xarxa")
            .navigationBarTitleDisplayMode(.inline)
            // Same rule as MapScreen: the loader task lives on the always-
            // visible container, not on the view that requires loaded data.
            .task(id: selectedLineCode) {
                guard let client = app.client else { return }
                let state = LineState(line: selectedLine, client: client)
                self.lineState = state
                await state.run()
            }
        }
        // Same as MapScreen: the sheet comes from the stack itself and its
        // detents are declared here, not inside the presented view (spec S9).
        .sheet(item: $selectedStation) { station in
            StationDetailView(station: station, line: selectedLine)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    /// Freshness of the line data and count of its incidents (spec S7).
    private var chipsRow: some View {
        HStack(spacing: 8) {
            if let state = lineState {
                FreshnessChip(lineState: state)
            }
            IncidentsChip(
                lineCode: selectedLineCode,
                lineDisplayName: selectedLine.displayName
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 16)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var content: some View {
        if let message = app.missingCredentialsMessage {
            ConfigurationNotice(message: message)
        } else if let state = lineState {
            diagram(state: state)
        } else {
            ProgressView("Carregant…")
        }
    }

    @ViewBuilder
    private func diagram(state: LineState) -> some View {
        let incidents = IncidentIndex.incidents(
            for: app.alerts,
            stations: state.stations,
            lineCode: selectedLine.code
        )
        // One clock per render for the regularity tags: the whole column is
        // rebuilt on every poll, so the tags recompute with it and never per
        // row (S7).
        let now = Date()
        let rows = Self.rowPlan(
            stations: state.stations,
            incidents: incidents,
            state: state,
            now: now
        )
        let incidentCount = incidents.values.reduce(0) { $0 + $1.count }
        ScrollView {
            VStack(spacing: 0) {
                if incidentCount > 0 {
                    IncidentSummaryBanner(
                        incidentCount: incidentCount,
                        lineName: selectedLine.displayName
                    )
                    .padding(16)
                }
                if state.isFeedEmpty {
                    // No arrivals feed for this line: say so above the rows
                    // instead of leaving a spine with no trains (spec S8).
                    NoRealtimeDataCard(theoretical: state.isTheoretical)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                }
                rowsColumn(state: state, rows: rows)
                    .padding(.top, incidentCount > 0 ? 0 : 16)
                    .padding(.bottom, 16)
            }
        }
        .refreshable {
            await state.pollArrivals()
        }
    }

    /// The station rows plus the trains, sharing one frame: the overlay is
    /// attached to the rows themselves, so its origin is the top of the first
    /// row and a train can never drift away from the rows it is drawn over
    /// (S6).
    private func rowsColumn(state: LineState, rows: [DiagramRowPlan]) -> some View {
        VStack(spacing: 0) {
            ForEach(rows) { row in
                DiagramRow(row: row, line: selectedLine)
                    .onTapGesture { selectedStation = row.station }
            }
        }
        .overlay(alignment: .topLeading) {
            TrainOverlay(state: state, line: selectedLine, rows: rows)
                .allowsHitTesting(false)
        }
    }

    /// One entry per station, in line order, with the incidents and arrivals
    /// it shows. The overlay reads the same plan the rows are drawn from, so
    /// both agree on every row's height.
    private static func rowPlan(
        stations: [Station],
        incidents: [Int: [StationIncident]],
        state: LineState,
        now: Date
    ) -> [DiagramRowPlan] {
        stations.enumerated().map { index, station in
            DiagramRowPlan(
                index: index,
                station: station,
                isFirst: index == 0,
                isLast: index == stations.count - 1,
                incidents: incidents[station.code] ?? [],
                arrivals: state.arrivalsByStop[station.code] ?? [],
                regularity: regularityTag(for: station, state: state, now: now)
            )
        }
    }

    /// The worse regularity of the two directions of a station, as the tag the
    /// row shows: a service gap outranks bunching, and anything else shows
    /// nothing (spec S7).
    private static func regularityTag(for station: Station, state: LineState, now: Date) -> DiagramRegularityTag? {
        // Two live arrivals are the minimum for any verdict, so a station the
        // feed does not even report twice is skipped instead of being asked.
        let live = (state.arrivalsByStop[station.code] ?? []).filter { $0.seconds != nil }
        guard live.count >= 2 else { return nil }
        var bunched = false
        for via in [1, 2] {
            guard let report = state.regularity(stationCode: station.code, via: via, now: now) else { continue }
            switch report.status {
            case .gap:
                guard let longestGap = report.longestGap else { continue }
                return .gap(minutes: Int((longestGap / 60).rounded()))
            case .bunched:
                bunched = true
            case .regular, .unknown:
                break
            }
        }
        return bunched ? .bunched : nil
    }
}

/// Regularity problem of one station row, computed once per render (spec S7).
/// The orange tag sits under the station name; nothing is drawn for a regular
/// or unknown station.
private enum DiagramRegularityTag {
    /// No train for roughly that long in one of the directions.
    case gap(minutes: Int)
    /// Two trains arrived close together after a gap.
    case bunched

    /// Catalan wording of the tag, metro lines (S7).
    var text: String {
        switch self {
        case .gap(let minutes): return "Buit de \(minutes) min"
        case .bunched: return "Trens pegats"
        }
    }
}

/// Everything one diagram row shows, and the height it occupies (S4). A row
/// with incidents is one `incidentLineHeight` taller per incident, and the
/// train overlay uses the same numbers to place the markers.
private struct DiagramRowPlan: Identifiable {
    /// The row's position in the line: the identity the rows are rendered by.
    /// A station code is not unique enough to key on (a line can list the same
    /// station twice), the index always is.
    let index: Int
    let station: Station
    let isFirst: Bool
    let isLast: Bool
    let incidents: [StationIncident]
    let arrivals: [Arrival]
    /// Regularity tag of the station, nil when there is nothing to report.
    let regularity: DiagramRegularityTag?

    var id: Int { index }

    /// A tag that replaces the accessible line costs the row nothing; one under
    /// a station without it is a 14 pt line of its own, and the train overlay
    /// reads the same number (S7).
    var height: CGFloat {
        var height = DiagramRow.baseHeight + DiagramRow.incidentLineHeight * CGFloat(incidents.count)
        if regularity != nil, !takesAccessibleLine {
            height += DiagramRow.regularityLineHeight
        }
        return height
    }

    /// True when the tag can sit on the line the "Accessible" label already
    /// occupies, instead of adding one.
    var takesAccessibleLine: Bool { station.accessible == true }
}

/// One station row of the diagram.
private struct DiagramRow: View {
    let row: DiagramRowPlan
    let line: MetroLine

    /// Height of a row without incidents; its center is where the station
    /// marker sits, so a train at a station is drawn on that marker (S6).
    static let baseHeight: CGFloat = 56
    static let incidentLineHeight: CGFloat = 18
    /// Height of the regularity tag line when the row adds one (S7).
    static let regularityLineHeight: CGFloat = 14
    static let horizontalPadding: CGFloat = 16
    static let markerSize: CGFloat = 24
    static let spineWidth: CGFloat = 5
    static let incidentBarWidth: CGFloat = 4

    static var markerCenterY: CGFloat { baseHeight / 2 }
    static var spineCenterX: CGFloat { horizontalPadding + markerSize / 2 }
    static var textLeading: CGFloat { horizontalPadding + markerSize + 12 }

    private var incidents: [StationIncident] { row.incidents }
    private var height: CGFloat { row.height }
    private var lineColor: Color { Color(hex: line.colorHex) }
    private var incidentColor: Color { Color(hex: "F59E0B") }

    var body: some View {
        content
            .padding(.leading, Self.textLeading)
            .padding(.trailing, Self.horizontalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: height)
            .background(rowBackground)
            .overlay(alignment: .topLeading) { spineColumn }
            .contentShape(Rectangle())
    }

    /// Name and accessibility on the marker line, incident lines under it.
    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.station.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if let regularity = row.regularity, row.takesAccessibleLine {
                        // On the line of the accessible label, so it keeps that
                        // label's intrinsic width and the pills stay right.
                        regularityLine(regularity)
                    } else if row.station.accessible == true {
                        Label("Accessible", image: "icon-accessible")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    if let forward = soonestArrival(via: 1) {
                        arrivalPill(forward)
                    }
                    if let backward = soonestArrival(via: 2) {
                        arrivalPill(backward)
                    }
                }
            }
            .frame(height: Self.baseHeight)
            // Station without the accessible line: the tag gets its own line,
            // which `DiagramRowPlan.height` already counted (S7).
            if let regularity = row.regularity, !row.takesAccessibleLine {
                regularityLine(regularity)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: Self.regularityLineHeight)
            }
            ForEach(incidents) { incident in
                incidentLine(incident)
            }
        }
    }

    /// Orange wash and the leading bar of a row that has incidents (S4).
    @ViewBuilder
    private var rowBackground: some View {
        if incidents.isEmpty {
            Color.clear
        } else {
            ZStack(alignment: .leading) {
                incidentColor.opacity(0.14)
                Rectangle()
                    .fill(incidentColor)
                    .frame(width: Self.incidentBarWidth)
            }
        }
    }

    /// The spine through the whole row and the line-colored station marker
    /// centered on it (S5). The spine is continuous across rows of different
    /// heights because every segment ends at a row edge, where the neighbour's
    /// own segment starts: inside a row the visible line runs from the marker
    /// center (first row) or the row top, down to the marker center (last row)
    /// or the row bottom.
    private var spineColumn: some View {
        let lineTop = row.isFirst ? Self.markerCenterY : CGFloat(0)
        let lineBottom = row.isLast ? Self.markerCenterY : height
        return ZStack(alignment: .top) {
            Color.clear
                .frame(width: Self.markerSize, height: height)
            Rectangle()
                .fill(lineColor)
                .frame(width: Self.spineWidth, height: max(lineBottom - lineTop, 0))
                .offset(y: lineTop)
            marker
                .padding(.top, Self.markerCenterY - Self.markerSize / 2)
        }
        .frame(width: Self.markerSize, height: height, alignment: .top)
        .padding(.leading, Self.horizontalPadding)
    }

    /// `terminal-<line>` at the two end stations, `station-<line>` elsewhere.
    private var marker: some View {
        Image((row.isFirst || row.isLast) ? "terminal-\(line.assetKey)" : "station-\(line.assetKey)")
            .resizable()
            .scaledToFit()
            .frame(width: Self.markerSize, height: Self.markerSize)
            .overlay(alignment: .topTrailing) {
                if !incidents.isEmpty {
                    incidentBadge
                }
            }
    }

    private var incidentBadge: some View {
        Image("icon-alert")
            .resizable()
            .scaledToFit()
            .frame(width: 14, height: 14)
            .foregroundStyle(incidentColor)
            .padding(2)
            .background(Circle().fill(.white))
            .offset(x: 3, y: 3)
    }

    /// The orange regularity tag: a small alert glyph and its wording (S7).
    /// Not width-filling: the caller decides where the line sits.
    private func regularityLine(_ regularity: DiagramRegularityTag) -> some View {
        HStack(spacing: 4) {
            Image("icon-alert")
                .resizable()
                .scaledToFit()
                .frame(width: 10, height: 10)
            Text(regularity.text)
                .lineLimit(1)
        }
        .font(.caption2.bold())
        .foregroundStyle(incidentColor)
    }

    private func incidentLine(_ incident: StationIncident) -> some View {
        HStack(spacing: 4) {
            Image(incident.kind.incidentIconAssetName)
                .resizable()
                .scaledToFit()
                .frame(width: 12, height: 12)
                .foregroundStyle(incidentColor)
            Text(incident.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(incidentColor)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Self.incidentLineHeight)
    }

    /// The soonest arrival of one direction (`via` 1 toward the last station,
    /// 2 toward the first). Arrivals without a via are not shown here (S5).
    private func soonestArrival(via: Int) -> Arrival? {
        row.arrivals
            .filter { $0.via == via && $0.seconds != nil }
            .min(by: { ($0.seconds ?? .max) < ($1.seconds ?? .max) })
    }

    private func arrivalPill(_ arrival: Arrival) -> some View {
        Text(pillText(arrival))
            .font(.caption2.bold())
            // Solid line colour with text chosen from its luminance: a tinted
            // capsule made the line-coloured text unreadable for L1, L2 and L5
            // in dark mode (spec S6).
            .foregroundStyle(HexLuminance.isLight(line.colorHex) ? Color.black : Color.white)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Capsule().fill(lineColor))
    }

    private func pillText(_ arrival: Arrival) -> String {
        let countdown = Arrival.countdownText(seconds: arrival.seconds ?? 0)
        let destination = arrival.destination.trimmingCharacters(in: .whitespaces)
        return destination.isEmpty ? countdown : "\(destination) \(countdown)"
    }
}

/// Summary of how many incidents the line has, above the rows (S4).
private struct IncidentSummaryBanner: View {
    let incidentCount: Int
    let lineName: String

    var body: some View {
        HStack(spacing: 8) {
            Image("icon-alert")
                .resizable()
                .scaledToFit()
                .frame(width: 16, height: 16)
            Text(incidentCount == 1
                ? "1 incidència a \(lineName)"
                : "\(incidentCount) incidències a \(lineName)")
                .font(.footnote.weight(.semibold))
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(hex: "F59E0B"), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(incidentCount == 1
            ? "1 incidència a \(lineName)"
            : "\(incidentCount) incidències a \(lineName)")
    }
}

/// A train placed in the diagram: its y already comes from the rows' heights.
private struct DiagramTrain: Identifiable {
    let id: String
    let assetKey: String
    let forward: Bool
    let y: CGFloat
}

/// Draws the live trains on the spine of the diagram (S6). It shares the rows'
/// coordinate space through the overlay it is attached to: every y is measured
/// from the top of the first row, so rows and trains cannot drift apart.
private struct TrainOverlay: View {
    let state: LineState
    let line: MetroLine
    let rows: [DiagramRowPlan]

    var body: some View {
        let trains = trainPlacements()
        // A ZStack so each `.position` is measured from the top-leading corner
        // of the rows' frame, the one coordinate space the overlay shares with
        // them (S6).
        ZStack(alignment: .topLeading) {
            ForEach(trains) { train in
                Image("train-\(train.assetKey)")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 42, height: 18.67)
                    .rotationEffect(.degrees(train.forward ? 90 : -90))
                    .position(x: DiagramRow.spineCenterX, y: train.y)
                    .accessibilityHidden(true)
            }
        }
    }

    private func trainPlacements() -> [DiagramTrain] {
        guard let engine = state.engine, !rows.isEmpty else { return [] }
        // Cumulative top of every row, taken from the same plan the rows are
        // drawn from: a fractional index therefore lands on the right pixel.
        var tops: [CGFloat] = []
        tops.reserveCapacity(rows.count)
        var top: CGFloat = 0
        for row in rows {
            tops.append(top)
            top += row.height
        }
        let lastIndex = rows.count - 1
        return state.positions.map { position in
            // The engine index is clamped to the station range first: the
            // fractional part is then always inside the row it belongs to, so
            // the last station maps to its own marker instead of one row past
            // it (S2, S6).
            let rawIndex = engine.stationIndexPosition(atRouteDistance: position.routeDistance)
            let index = min(max(rawIndex, 0), Double(lastIndex))
            let lower = Int(index)
            let fraction = index - Double(lower)
            let y = tops[lower] + CGFloat(fraction) * rows[lower].height
                + DiagramRow.baseHeight / 2
            let trainLine = MetroLine.line(forCode: position.lineCode) ?? line
            return DiagramTrain(
                id: position.id,
                assetKey: trainLine.assetKey,
                forward: position.forward,
                y: y
            )
        }
    }
}
