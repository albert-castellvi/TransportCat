import SwiftUI

/// Parades, bus (spec S9, mockup `V4Bus`): the stops of the selected line and
/// direction as rows on a rail in the line colour, each with its name, its
/// street and the next two buses of that direction; live buses drawn on the
/// rail as S6 markers (solid ring, D5); incidents as orange rows.
///
/// One direction at a time (spec S9): the choice is resolved from the shared
/// storage key through `BusDirectionSelection.resolve` — the helper T1 lands
/// in parallel — so the accessory's swap button and this screen always show
/// the same direction. The screen carries no top header any more: the status
/// capsule (`FreshnessChip`, styled by T1) and the direction strip are all.
///
/// The metro timeline keeps its row and card types `private` to its own file,
/// and bus lines differ in two concrete ways (no pre-rendered
/// `station-`/`terminal-` markers, arrivals per direction), so this file
/// carries its own `Bus`-prefixed copies of that geometry instead of reopening
/// it.
struct BusDiagramScreen: View {
    @EnvironmentObject private var app: AppModel
    /// Catalog and selection state, shared with the bus map so both screens
    /// always show the same line (spec S2). The key `busSelectedLine` is
    /// owned by `BusCatalogStore` and is never renamed (S15).
    @State private var store = BusCatalogStore.shared
    /// Polling state of the line on screen; recreated whenever the selected bus
    /// line changes.
    @State private var lineState: BusLineState?
    /// Stored direction choice under the SAME key the T1 accessory writes
    /// (`BusDirectionSelection.storageKey`): 1 Anada, 2 Tornada.
    @AppStorage(BusDirectionSelection.storageKey) private var storedDirectionID = 1
    @State private var showLinePicker = false
    /// Stop whose sheet is open. `BusStop` is `Identifiable` with a key that
    /// includes the direction, so `sheet(item:)` can use it directly.
    @State private var selectedStop: BusStop?

    init() {}

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                statusCapsule
                content
            }
            // The bottom accessory (T1) carries the mode menu, the line chip
            // and the direction swap; the screen keeps no title bar (S5).
            // The icon's network behind the top, fading out (spec S11).
            .networkHeaderBackground(opacity: 0.45)
            .navigationBarHidden(true)
            // The catalog loads once per launch (spec S2), and both loader
            // tasks live on the always-visible container, as in MapScreen: a
            // task on the rows would never start while the line is unknown.
            .task {
                guard let client = app.client else { return }
                await store.load(client: client)
            }
            // Keyed on the resolved line, not the stored code: the stored code
            // is restored from UserDefaults before the catalog loads, so the
            // task would exit through the guard and never re-run.
            .task(id: store.selectedLine?.code) {
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
            // Keep the chosen direction valid when the screen switches to a
            // line that does not publish it, so the timeline always shows a
            // real selection (the same rule the old `Picker` followed).
            .onChange(of: lineState?.directions.map(\.id)) { _, ids in
                guard let ids else { return }
                if let resolved = BusDirectionSelection.resolve(stored: storedDirectionID, available: ids),
                   resolved != storedDirectionID {
                    storedDirectionID = resolved
                }
            }
        }
        // The stop sheet comes from the stack itself and declares its detents
        // here, not inside the presented view, as MapScreen does.
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

    /// The status capsule, top-left (spec S2): the existing `FreshnessChip`
    /// explicit-values initializer, restyled by T1 — this screen only calls it.
    @ViewBuilder
    private var statusCapsule: some View {
        Group {
            if let state = lineState {
                FreshnessChip(
                    updatedAt: state.arrivalsUpdatedAt,
                    lastAttemptFailed: state.lastPollFailed
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let message = app.missingCredentialsMessage {
            ConfigurationNotice(message: message)
        } else if let state = lineState {
            timeline(state: state)
        } else if let message = store.errorMessage {
            // The catalog sheet reached from the accessory's line chip offers
            // the retry; here the reason is only stated.
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
    private func timeline(state: BusLineState) -> some View {
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
                direction: direction
            )
            let nearest = ParadesTimeline.nearestStation(
                stations: direction.stops.map { $0.asStation(lineCode: lineCode) },
                userLocation: LocationService.shared.location
            )
            ScrollView {
                VStack(spacing: 0) {
                    if let error = state.errorMessage {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 16)
                            .padding(.top, 8)
                    }
                    directionStrip(direction: direction)
                        .padding(.top, 8)
                    if state.hasNoBuses {
                        // A line with no bus in the feed would otherwise read
                        // as a broken list (spec S9).
                        BusNoServiceCard()
                            .padding(.horizontal, 16)
                            .padding(.top, 8)
                    }
                    rowsColumn(
                        state: state,
                        direction: direction,
                        rows: rows,
                        nearestCode: nearest?.station.code,
                        hereText: nearest.map { ParadesTimeline.hereText(distanceMeters: $0.distanceMeters) }
                    )
                    .padding(.top, 4)
                    .padding(.bottom, 16)
                }
            }
        } else {
            placeholder(state: state)
        }
    }

    /// The direction strip of the timeline (mockup `V4Bus`): where the shown
    /// direction is heading, and the two column captions. The swap itself is
    /// the accessory's (T1); this strip only states what is on screen.
    private func directionStrip(direction: BusDirection) -> some View {
        HStack {
            Text("Cap a \(direction.destinationName)")
            Spacer()
            Text("Pròxims busos")
        }
        .font(.caption.weight(.bold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.thinMaterial)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Cap a \(direction.destinationName), pròxims busos")
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

    /// The direction on screen: the stored choice resolved through the shared
    /// helper against the directions the line publishes, falling back to the
    /// first one when nothing matches (a line with a single direction, or a
    /// fresh state for another line).
    private func selectedDirection(in state: BusLineState) -> BusDirection? {
        let available = state.directions.map(\.id)
        if let resolved = BusDirectionSelection.resolve(stored: storedDirectionID, available: available) {
            return state.directions.first { $0.id == resolved }
        }
        return state.directions.first
    }

    // MARK: - Rows

    /// The stop rows plus the buses, sharing one frame: the overlay is
    /// attached to the rows themselves, so its origin is the top of the first
    /// row and a bus can never drift away from the rows it is drawn over.
    private func rowsColumn(
        state: BusLineState,
        direction: BusDirection,
        rows: [BusDiagramRowPlan],
        nearestCode: Int?,
        hereText: String?
    ) -> some View {
        VStack(spacing: 0) {
            ForEach(rows) { row in
                BusDiagramRow(
                    row: row,
                    line: state.line,
                    isNearest: row.stop.code == nearestCode,
                    hereText: row.stop.code == nearestCode ? hereText : nil
                )
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

    /// One entry per stop of the direction, in order, with the incidents and
    /// the next two buses it shows. The overlay reads the same plan the rows
    /// are drawn from, so both agree on every row's height (spec S9).
    private static func rowPlan(
        stops: [BusStop],
        incidents: [Int: [StationIncident]],
        state: BusLineState,
        direction: BusDirection
    ) -> [BusDiagramRowPlan] {
        stops.enumerated().map { index, stop in
            let arrivals = (state.arrivalsByStop[stop.code] ?? [])
                .filter { $0.directionID == direction.id }
            let nextTwo = ParadesTimeline.busNextTwo(arrivals: arrivals, directionID: direction.id)
            return BusDiagramRowPlan(
                index: index,
                stop: stop,
                isFirst: index == 0,
                isLast: index == stops.count - 1,
                incidents: incidents[stop.code] ?? [],
                next: nextTwo.next,
                after: nextTwo.after
            )
        }
    }

    /// Incidents of one stop on the line, for its sheet (spec S7). Computed
    /// the way the station detail does it, from the alerts already in the
    /// model.
    private func incidents(for stop: BusStop, line: BusLine) -> [StationIncident] {
        let lineCode = String(line.code)
        return IncidentIndex.incidents(
            for: app.activeBusAlerts(affecting: lineCode),
            stations: [stop.asStation(lineCode: lineCode)],
            lineCode: lineCode
        )[stop.code] ?? []
    }

    /// The delay of each bus the sheet lists, estimated against the timetable
    /// (spec S7): the ids this stop's arrivals already name, read from the
    /// last poll, so the sheet never triggers a request of its own.
    private func delays(for stop: BusStop, in state: BusLineState) -> [Int: DelayEstimate] {
        var estimates: [Int: DelayEstimate] = [:]
        for arrival in state.arrivalsByStop[stop.code] ?? [] {
            guard let busID = arrival.busID, let estimate = state.delay(forBus: busID) else { continue }
            estimates[busID] = estimate
        }
        return estimates
    }
}

/// Everything one bus timeline row shows, and the height it occupies. A row
/// with incidents is one `incidentLineHeight` taller per incident, and the bus
/// overlay uses the same numbers to place the bus markers (spec S9).
private struct BusDiagramRowPlan: Identifiable {
    /// Position in the direction: the identity the rows are rendered by. A
    /// stop code repeats between the two directions, the index of one
    /// direction always is unique.
    let index: Int
    let stop: BusStop
    let isFirst: Bool
    let isLast: Bool
    let incidents: [StationIncident]
    /// Next bus of this direction at this stop; nil when the stop was not
    /// polled or no bus is announced (spec S9).
    let next: BusArrival?
    /// Second bus, drawn smaller under the first; nil with one arrival.
    let after: BusArrival?

    var id: Int { index }

    var height: CGFloat {
        BusDiagramRow.baseHeight + BusDiagramRow.incidentLineHeight * CGFloat(incidents.count)
    }
}

/// One stop row of the bus timeline (spec S9, mockup `V4Bus`): the stop
/// marker on the rail, the name with its street, and the next two buses.
private struct BusDiagramRow: View {
    let row: BusDiagramRowPlan
    let line: BusLine
    /// Whether "Ets aquí · <distance>" is drawn on this row.
    let isNearest: Bool
    let hereText: String?

    /// Height of a row without incidents; its center is where the stop marker
    /// sits, so a bus at a stop is drawn on that marker (spec S9).
    static let baseHeight: CGFloat = 66
    static let incidentLineHeight: CGFloat = 18
    static let horizontalPadding: CGFloat = 16
    static let spineWidth: CGFloat = 5
    static let incidentBarWidth: CGFloat = 4
    /// Marker column: the metro timeline centers its 26 pt marker on
    /// x = 16 + 13 = 29; the drawn bus dots share the same spine center.
    static let markerColumnLeading: CGFloat = 20
    static let markerColumnWidth: CGFloat = 18
    static let markerSize: CGFloat = 16
    static let terminalMarkerSize: CGFloat = 20
    static let markerStrokeWidth: CGFloat = 3
    static let textLeading: CGFloat = 52

    static var markerCenterY: CGFloat { baseHeight / 2 }
    static var spineCenterX: CGFloat { Self.markerColumnLeading + Self.markerColumnWidth / 2 }

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
            .background {
                // Branches of different view types: a builder, not a ternary.
                if isNearest {
                    Color(hex: "409CFF").opacity(0.12)
                } else {
                    rowBackground
                }
            }
            .overlay(alignment: .topLeading) { spineColumn }
            .contentShape(Rectangle())
    }

    /// Stop name and street on the marker line, incident lines under it.
    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.stop.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        if let hereText {
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(Color(hex: "409CFF"))
                                    .frame(width: 8, height: 8)
                                Text(hereText)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(Color(hex: "409CFF"))
                            }
                        }
                        if !row.stop.address.isEmpty {
                            Text(row.stop.address)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                Spacer(minLength: 8)
                timesColumn
            }
            .frame(height: Self.baseHeight)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)
            ForEach(incidents) { incident in
                incidentLine(incident)
            }
        }
    }

    /// The next two buses of the direction (spec S9): "<n> min" big, second
    /// smaller; "ara" in green; "Sense dada" when the poll saw none.
    @ViewBuilder
    private var timesColumn: some View {
        VStack(alignment: .trailing, spacing: 2) {
            if let next = row.next {
                Text(ParadesTimeline.busTimeText(seconds: next.seconds))
                    .font(.callout.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(
                        next.seconds <= ParadesTimeline.imminentThresholdSeconds
                            ? Color(hex: "30D158")
                            : Color.primary
                    )
            } else {
                Text("—")
                    .font(.callout.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if let after = row.after {
                Text(ParadesTimeline.busTimeText(seconds: after.seconds))
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else if row.next == nil {
                Text("Sense dada")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 72, alignment: .trailing)
    }

    private var accessibilityText: String {
        var parts: [String] = [row.stop.name]
        if let hereText { parts.append(hereText) }
        if let next = row.next {
            parts.append("Bus en \(ParadesTimeline.busTimeText(seconds: next.seconds))")
        } else {
            parts.append("Sense dada")
        }
        if let after = row.after {
            parts.append("i en \(ParadesTimeline.busTimeText(seconds: after.seconds))")
        }
        return parts.joined(separator: ", ")
    }

    /// Orange wash and the leading bar of a row that has incidents.
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

    /// The rail through the whole row and the stop marker centered on it. The
    /// rail is continuous across rows of different heights because every
    /// segment ends at a row edge, where the neighbour's own segment starts.
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

/// A bus placed in the timeline, at the y its route distance gives.
private struct BusDiagramPlacement: Identifiable {
    let id: String
    let y: CGFloat
    /// True toward the last stop of the direction, i.e. down the rows.
    let forward: Bool
}

/// Draws the live buses on the rail with the S6 vehicle marker (D5: solid
/// ring, all bus positions are arrival-based estimates, which the vehicle
/// card says — the dashed ring stays reserved for metro). It shares the rows'
/// coordinate space through the overlay it is attached to: every y is
/// measured from the top of the first row, so rows and buses cannot drift
/// apart.
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
                VehicleMarkerView(
                    colorHex: line.colorHex,
                    glyph: .bus,
                    headingDegrees: bus.forward ? 180 : 0,
                    isEstimated: false,
                    isSelected: false,
                    size: 30
                )
                .position(x: BusDiagramRow.spineCenterX, y: bus.y)
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
            // fraction is then always inside the row it belongs to, so the
            // last stop maps to its own marker instead of one row past it.
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
