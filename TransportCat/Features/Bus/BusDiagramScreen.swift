import SwiftUI

/// Bus version of the Xarxa diagram (spec S8): the stops of the selected line
/// and direction as rows on a spine in the line colour, with the soonest polled
/// arrival at each stop, the line's incidents as orange rows, and the live buses
/// drawn on the spine at their continuous position.
///
/// The metro diagram keeps its row, banner and train types `private` to its own
/// file, and bus lines differ in two concrete ways (no pre-rendered
/// `station-`/`terminal-` markers, arrivals per direction), so this file carries
/// its own `Bus`-prefixed copies of that geometry instead of reopening it.
struct BusDiagramScreen: View {
    @EnvironmentObject private var app: AppModel
    /// Catalog and picker state, shared with the bus map so both screens always
    /// show the same line (spec S2).
    @State private var store = BusCatalogStore.shared
    /// Polling state of the line on screen; recreated whenever the selected bus
    /// line changes.
    @State private var lineState: BusLineState?
    /// `BusDirection.id` of the direction shown: 1 Anada, 2 Tornada (spec S8).
    @State private var selectedDirectionID = 1
    @State private var showLinePicker = false
    /// Stop whose sheet is open. `BusStop` is `Identifiable` with a key that
    /// includes the direction, so `sheet(item:)` can use it directly.
    @State private var selectedStop: BusStop?

    init() {}

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                content
            }
            .navigationTitle("Línies")
            .navigationBarTitleDisplayMode(.inline)
            // The catalog loads once per launch (spec S2), and both loader tasks
            // live on the always-visible container, as in MapScreen: a task on
            // the rows would never start while the line is still unknown.
            .task {
                guard let client = app.client else { return }
                await store.load(client: client)
            }
            .task(id: store.selectedLineCode) {
                guard let client = app.client, let line = store.selectedLine else { return }
                let state = BusLineState(line: line, client: client)
                self.lineState = state
                await state.run()
            }
            .sheet(isPresented: $showLinePicker) {
                BusLinePickerSheet(store: store) { line in
                    store.selectedLineCode = line.code
                }
            }
            // Keep the chosen direction valid when the screen switches to a line
            // that does not publish it, so the segments always show a selection.
            .onChange(of: lineState?.directions.map(\.id)) { _, ids in
                guard let ids, !ids.contains(selectedDirectionID) else { return }
                selectedDirectionID = ids.first ?? 1
            }
        }
        // The stop sheet comes from the stack itself and declares its detents
        // here, not inside the presented view (spec S9), as MapScreen does.
        .sheet(item: $selectedStop) { stop in
            if let state = lineState {
                BusStopSheet(
                    stop: stop,
                    line: state.line,
                    incidents: incidents(for: stop, line: state.line),
                    delays: delays(for: stop, in: state)
                )
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    // MARK: - Header

    /// Mode selector, line selector, direction segments, chips (spec S1, S2, S8).
    /// Same rows, paddings and order as `BusMapScreen`, so the two bus screens
    /// read as one tab.
    private var header: some View {
        VStack(spacing: 0) {
            ModeSelector()
                .padding(.horizontal, 16)
                .padding(.top, 8)
            BusLineButton(line: store.selectedLine) {
                showLinePicker = true
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            directionControl
            chipsRow
        }
    }

    /// "Anada · <destination>" / "Tornada · <destination>" (spec S8). Hidden
    /// while the stops of the line have not arrived, when there is nothing to
    /// choose.
    @ViewBuilder
    private var directionControl: some View {
        if let state = lineState, !state.directions.isEmpty {
            Picker("Direcció", selection: $selectedDirectionID) {
                ForEach(state.directions) { direction in
                    Text("\(direction.name) · \(direction.destinationName)")
                        .tag(direction.id)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    /// Freshness of the bus poll and count of the line's incidents (spec S3, S7).
    @ViewBuilder
    private var chipsRow: some View {
        if let line = store.selectedLine {
            HStack(spacing: 8) {
                if let state = lineState {
                    FreshnessChip(
                        updatedAt: state.arrivalsUpdatedAt,
                        lastAttemptFailed: state.lastPollFailed
                    )
                }
                IncidentsChip(busLineCode: String(line.code), lineDisplayName: line.name)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 16)
            .padding(.bottom, 8)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let message = app.missingCredentialsMessage {
            ConfigurationNotice(message: message)
        } else if let state = lineState {
            diagram(state: state)
        } else if let message = store.errorMessage {
            // The catalog sheet reached from the line selector offers the
            // retry; here the reason is only stated.
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgressView("Carregant…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func diagram(state: BusLineState) -> some View {
        if let direction = selectedDirection(in: state) {
            let lineCode = String(state.line.code)
            let incidents = IncidentIndex.incidents(
                for: app.activeBusAlerts(affecting: lineCode),
                stations: direction.stops.map { $0.asStation(lineCode: lineCode) },
                lineCode: lineCode
            )
            let rows = Self.rowPlan(
                stops: direction.stops,
                incidents: incidents,
                state: state,
                direction: direction,
                now: Date()
            )
            let incidentCount = incidents.values.reduce(0) { $0 + $1.count }
            ScrollView {
                VStack(spacing: 0) {
                    if let error = state.errorMessage {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 16)
                            .padding(.top, 8)
                    }
                    if incidentCount > 0 {
                        BusIncidentSummaryBanner(
                            incidentCount: incidentCount,
                            lineName: state.line.name
                        )
                        .padding(16)
                    }
                    if state.hasNoBuses {
                        // A line with no bus in the feed would otherwise read as
                        // a broken list (spec S9).
                        BusNoServiceCard()
                            .padding(.horizontal, 16)
                            .padding(.bottom, 8)
                    }
                    rowsColumn(state: state, direction: direction, rows: rows)
                        .padding(.top, incidentCount > 0 ? 0 : 16)
                        .padding(.bottom, 16)
                }
            }
        } else {
            placeholder(state: state)
        }
    }

    /// Nothing to draw yet: the stops of the line have not arrived, or loading
    /// them failed.
    @ViewBuilder
    private func placeholder(state: BusLineState) -> some View {
        if let error = state.errorMessage, !state.isLoading {
            Text(error)
                .font(.footnote)
                .foregroundStyle(.red)
                .padding(16)
        } else {
            ProgressView("Carregant…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The direction on screen: the one the user picked, falling back to the
    /// first the line publishes when that id is not in the list (a line with a
    /// single direction, or a fresh state for another line).
    private func selectedDirection(in state: BusLineState) -> BusDirection? {
        state.directions.first { $0.id == selectedDirectionID } ?? state.directions.first
    }

    // MARK: - Rows

    /// The stop rows plus the buses, sharing one frame: the overlay is attached
    /// to the rows themselves, so its origin is the top of the first row and a
    /// bus can never drift away from the rows it is drawn over (spec S8).
    private func rowsColumn(state: BusLineState, direction: BusDirection, rows: [BusDiagramRowPlan]) -> some View {
        VStack(spacing: 0) {
            ForEach(rows) { row in
                BusDiagramRow(row: row, line: state.line)
                    .onTapGesture { selectedStop = row.stop }
            }
        }
        .overlay(alignment: .topLeading) {
            BusTrainOverlay(
                direction: direction,
                line: state.line,
                rows: rows,
                positions: state.positions.filter { $0.directionID == direction.id }
            )
            .allowsHitTesting(false)
        }
    }

    /// One entry per stop of the direction, in order, with the incidents and the
    /// soonest arrival it shows. The overlay reads the same plan the rows are
    /// drawn from, so both agree on every row's height (spec S8).
    private static func rowPlan(
        stops: [BusStop],
        incidents: [Int: [StationIncident]],
        state: BusLineState,
        direction: BusDirection,
        now: Date
    ) -> [BusDiagramRowPlan] {
        // Regularity needs the arrivals of polled stops; the rest have nothing
        // to assess (spec S7).
        let polledCodes = Set(direction.polledStops.map(\.code))
        stops.enumerated().map { index, stop in
            // Only polled stops have arrivals at all, and only those of the
            // direction on screen get a pill (spec S5, S8).
            let arrivals = (state.arrivalsByStop[stop.code] ?? []).filter { $0.directionID == direction.id }
            return BusDiagramRowPlan(
                index: index,
                stop: stop,
                isFirst: index == 0,
                isLast: index == stops.count - 1,
                incidents: incidents[stop.code] ?? [],
                arrival: arrivals.min(by: { $0.seconds < $1.seconds }),
                // Two arrivals of the direction are the minimum for a verdict,
                // so a stop with less is not asked at all (S3, S7).
                regularity: polledCodes.contains(stop.code) && arrivals.count >= 2
                    ? regularityTag(stopCode: stop.code, directionID: direction.id, state: state, now: now)
                    : nil
            )
        }
    }

    /// The orange tag of a bus stop row: a service gap outranks bunching, and a
    /// regular or unknown report shows nothing (spec S7).
    private static func regularityTag(
        stopCode: Int,
        directionID: Int,
        state: BusLineState,
        now: Date
    ) -> BusDiagramRegularityTag? {
        guard let report = state.regularity(stopCode: stopCode, directionID: directionID, now: now) else { return nil }
        switch report.status {
        case .gap:
            guard let longestGap = report.longestGap else { return nil }
            return .gap(minutes: Int((longestGap / 60).rounded()))
        case .bunched:
            return .bunched
        case .regular, .unknown:
            return nil
        }
    }

    /// Incidents of one stop on the line, for its sheet (spec S7). Computed the
    /// way the station detail does it, from the alerts already in the model.
    private func incidents(for stop: BusStop, line: BusLine) -> [StationIncident] {
        let lineCode = String(line.code)
        return IncidentIndex.incidents(
            for: app.activeBusAlerts(affecting: lineCode),
            stations: [stop.asStation(lineCode: lineCode)],
            lineCode: lineCode
        )[stop.code] ?? []
    }

    /// The delay of each bus the sheet lists, estimated against the timetable
    /// (spec S7): the ids this stop's arrivals already name, read from the last
    /// poll, so the sheet never triggers a request of its own.
    private func delays(for stop: BusStop, in state: BusLineState) -> [Int: DelayEstimate] {
        var estimates: [Int: DelayEstimate] = [:]
        for arrival in state.arrivalsByStop[stop.code] ?? [] {
            guard let busID = arrival.busID, let estimate = state.delay(forBus: busID) else { continue }
            estimates[busID] = estimate
        }
        return estimates
    }
}

/// Regularity problem of one bus stop row, computed once per render (spec S7).
private enum BusDiagramRegularityTag {
    /// No bus of this direction for roughly that long.
    case gap(minutes: Int)
    /// Two buses arrived close together after a gap.
    case bunched

    /// Catalan wording of the tag, bus lines (S7).
    var text: String {
        switch self {
        case .gap(let minutes): return "Buit de \(minutes) min"
        case .bunched: return "Busos pegats"
        }
    }
}

/// Everything one bus diagram row shows, and the height it occupies. A row with
/// incidents is one `incidentLineHeight` taller per incident, and the bus
/// overlay uses the same numbers to place the bus markers (spec S8).
private struct BusDiagramRowPlan: Identifiable {
    /// Position in the direction: the identity the rows are rendered by. A stop
    /// code repeats between the two directions, the index of one direction
    /// always is unique.
    let index: Int
    let stop: BusStop
    let isFirst: Bool
    let isLast: Bool
    let incidents: [StationIncident]
    /// Soonest bus of this direction at this stop; nil when the stop was not
    /// polled or no bus is announced (spec S5).
    let arrival: BusArrival?
    /// Regularity tag of the stop, nil when there is nothing to report.
    let regularity: BusDiagramRegularityTag?

    var id: Int { index }

    /// A row that shows the tag is one 14 pt line taller, and the bus overlay
    /// reads the same number, so the spine stays continuous (spec S7). The
    /// address line is kept: unlike the metro rows, the bus rows have no
    /// decorative line the tag could take over.
    var height: CGFloat {
        var height = BusDiagramRow.baseHeight + BusDiagramRow.incidentLineHeight * CGFloat(incidents.count)
        if regularity != nil {
            height += BusDiagramRow.regularityLineHeight
        }
        return height
    }
}

/// One stop row of the bus diagram.
private struct BusDiagramRow: View {
    let row: BusDiagramRowPlan
    let line: BusLine

    /// Height of a row without incidents; its center is where the stop marker
    /// sits, so a bus at a stop is drawn on that marker (spec S8).
    static let baseHeight: CGFloat = 56
    static let incidentLineHeight: CGFloat = 18
    /// Height of the regularity tag line when the row shows one (spec S7).
    static let regularityLineHeight: CGFloat = 14
    static let horizontalPadding: CGFloat = 16
    static let spineWidth: CGFloat = 5
    static let incidentBarWidth: CGFloat = 4
    /// Marker column: the metro diagram centers its 24 pt asset on x = 16 + 12 =
    /// 28, and bus lines publish no such asset, so the dots are drawn with the
    /// same spine center.
    static let spineCenterX: CGFloat = 28
    static let markerColumnLeading: CGFloat = 18
    static let markerColumnWidth: CGFloat = 20
    static let markerSize: CGFloat = 16
    static let terminalMarkerSize: CGFloat = 20
    static let markerStrokeWidth: CGFloat = 3
    static let textLeading: CGFloat = 50

    static var markerCenterY: CGFloat { baseHeight / 2 }

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

    /// Stop name and address on the marker line, incident lines under it.
    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.stop.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if !row.stop.address.isEmpty {
                        Text(row.stop.address)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if let arrival = row.arrival {
                    arrivalPill(arrival)
                }
            }
            .frame(height: Self.baseHeight)
            if let regularity = row.regularity {
                regularityLine(regularity)
                    .frame(height: Self.regularityLineHeight)
            }
            ForEach(incidents) { incident in
                incidentLine(incident)
            }
        }
    }

    /// Orange wash and the leading bar of a row that has incidents, as in the
    /// metro Xarxa (spec S8).
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

    /// The spine through the whole row and the stop marker centered on it. The
    /// spine is continuous across rows of different heights because every
    /// segment ends at a row edge, where the neighbour's own segment starts:
    /// inside a row the visible line runs from the marker center (first row) or
    /// the row top, down to the marker center (last row) or the row bottom.
    private var spineColumn: some View {
        let lineTop = row.isFirst ? Self.markerCenterY : CGFloat(0)
        let lineBottom = row.isLast ? Self.markerCenterY : height
        return ZStack(alignment: .top) {
            Color.clear
                .frame(width: Self.markerColumnWidth, height: height)
            Rectangle()
                .fill(lineColor)
                .frame(width: Self.spineWidth, height: max(lineBottom - lineTop, 0))
                .offset(y: lineTop)
            marker
                .padding(.top, Self.markerCenterY - markerSizeUsed / 2)
        }
        .frame(width: Self.markerColumnWidth, height: height, alignment: .top)
        .padding(.leading, Self.markerColumnLeading)
    }

    /// The two end stops of a direction get the larger, line-colored dot; the
    /// rest are the plain black dot with a white ring. Bus lines publish no
    /// `station-`/`terminal-` assets, so the marker is drawn, not loaded.
    private var marker: some View {
        Circle()
            .fill(row.isFirst || row.isLast ? lineColor : Color.black)
            .frame(width: markerSizeUsed, height: markerSizeUsed)
            .overlay(Circle().stroke(.white, lineWidth: Self.markerStrokeWidth))
            .overlay(alignment: .topTrailing) {
                if !incidents.isEmpty {
                    incidentBadge
                }
            }
    }

    private var markerSizeUsed: CGFloat {
        row.isFirst || row.isLast ? Self.terminalMarkerSize : Self.markerSize
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
    private func regularityLine(_ regularity: BusDiagramRegularityTag) -> some View {
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
        .frame(maxWidth: .infinity, alignment: .leading)
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

    /// Countdown of the soonest bus of this direction, on a capsule filled with
    /// the line colour. The text colour follows the fill, as the metro pills do
    /// (spec S6, S8).
    private func arrivalPill(_ arrival: BusArrival) -> some View {
        Text(Arrival.countdownText(seconds: arrival.seconds))
            .font(.caption2.bold())
            .foregroundStyle(HexLuminance.isLight(line.colorHex) ? Color.black : Color.white)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Capsule().fill(lineColor))
            .accessibilityLabel("Bus \(Arrival.countdownText(seconds: arrival.seconds))")
    }
}

/// Summary of how many incidents the direction has, above the rows (spec S8).
private struct BusIncidentSummaryBanner: View {
    let incidentCount: Int
    let lineName: String

    var body: some View {
        HStack(spacing: 8) {
            Image("icon-alert")
                .resizable()
                .scaledToFit()
                .frame(width: 16, height: 16)
            Text(title)
                .font(.footnote.weight(.semibold))
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(hex: "F59E0B"), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }

    /// "1 incidència a H12" / "4 incidències a H12".
    private var title: String {
        incidentCount == 1
            ? "1 incidència a \(lineName)"
            : "\(incidentCount) incidències a \(lineName)"
    }
}

/// Notice for a bus line with no bus in the feed (spec S9). The list keeps its
/// rows underneath: the stops are real, only the live position is missing.
private struct BusNoServiceCard: View {
    var body: some View {
        VStack(spacing: 8) {
            Image("icon-realtime-off")
                .resizable()
                .scaledToFit()
                .frame(width: 32, height: 32)
                .foregroundStyle(.secondary)
            Text("Cap bus en servei ara")
                .font(.headline)
                .multilineTextAlignment(.center)
            Text("No hi ha cap bus previst en aquesta línia ara mateix.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }
}

/// A bus placed in the diagram, at the y its route distance gives, turned the
/// way it travels along the spine.
private struct BusDiagramPlacement: Identifiable {
    let id: String
    let y: CGFloat
    /// True toward the last stop of the direction, i.e. down the rows.
    let forward: Bool
}

/// Draws the live buses on the spine of the diagram (spec S8). It shares the
/// rows' coordinate space through the overlay it is attached to: every y is
/// measured from the top of the first row, so rows and buses cannot drift
/// apart. The buses are the same pictograms the map uses, turned 90 degrees so
/// they lie along the vertical spine (spec S2).
private struct BusTrainOverlay: View {
    let direction: BusDirection
    let line: BusLine
    let rows: [BusDiagramRowPlan]
    let positions: [BusPosition]

    var body: some View {
        // A ZStack so each `.position` is measured from the top-leading corner
        // of the rows' frame, the one coordinate space the overlay shares with
        // them.
        ZStack(alignment: .topLeading) {
            ForEach(placements()) { bus in
                BusDiagramMarker(line: line, forward: bus.forward)
                    .position(x: BusDiagramRow.spineCenterX, y: bus.y)
                    .accessibilityHidden(true)
            }
        }
    }

    private func placements() -> [BusDiagramPlacement] {
        guard !rows.isEmpty else { return [] }
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
        return positions.map { position in
            // The fractional stop index is clamped to the row range first: the
            // fraction is then always inside the row it belongs to, so the last
            // stop maps to its own marker instead of one row past it.
            let rawIndex = direction.stopIndexPosition(atRouteDistance: position.train.routeDistance)
            let index = min(max(rawIndex, 0), Double(lastIndex))
            let lower = Int(index)
            let fraction = index - Double(lower)
            let y = tops[lower] + CGFloat(fraction) * rows[lower].height
                + BusDiagramRow.baseHeight / 2
            return BusDiagramPlacement(
                id: position.id,
                y: y,
                forward: position.train.forward
            )
        }
    }
}

/// The bus itself on the spine: the same `bus-<colorHex>` pictogram the map
/// draws, turned along the spine, ringed by nothing because the art already
/// carries its own white outline (spec S2, S8). No name chip here: every row
/// already says which line it is.
private struct BusDiagramMarker: View {
    let line: BusLine
    let forward: Bool

    var body: some View {
        Image(BusMarker.assetName(for: line))
            .resizable()
            .scaledToFit()
            .frame(
                width: BusMarker.markerSize.width,
                height: BusMarker.markerSize.height
            )
            .rotationEffect(.degrees(forward ? 90 : -90))
    }
}
