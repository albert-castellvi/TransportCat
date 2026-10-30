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
        let rows = Self.rowPlan(
            stations: state.stations,
            incidents: incidents,
            arrivalsByStop: state.arrivalsByStop
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
                    NoRealtimeDataCard()
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
        arrivalsByStop: [Int: [Arrival]]
    ) -> [DiagramRowPlan] {
        stations.enumerated().map { index, station in
            DiagramRowPlan(
                index: index,
                station: station,
                isFirst: index == 0,
                isLast: index == stations.count - 1,
                incidents: incidents[station.code] ?? [],
                arrivals: arrivalsByStop[station.code] ?? []
            )
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

    var id: Int { index }

    var height: CGFloat {
        DiagramRow.baseHeight + DiagramRow.incidentLineHeight * CGFloat(incidents.count)
    }
}

/// One station row of the diagram.
private struct DiagramRow: View {
    let row: DiagramRowPlan
    let line: MetroLine

    /// Height of a row without incidents; its center is where the station
    /// marker sits, so a train at a station is drawn on that marker (S6).
    static let baseHeight: CGFloat = 56
    static let incidentLineHeight: CGFloat = 18
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
                    if row.station.accessible == true {
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
                    .frame(width: 36, height: 30)
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
