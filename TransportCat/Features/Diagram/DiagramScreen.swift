import SwiftUI

extension IncidentKind {
    /// Asset catalog name of the icon that identifies an incident kind in the
    /// Parades timeline and in the station detail (S4, S7). Shared by both
    /// views so the icon of a kind never differs between them.
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

/// Parades, metro (spec S8, mockup `V4Metro`): one row per station on a rail
/// in the line colour — dotted on affected runs — with the two tabular time
/// columns per direction, metro interchange badges, "Ets aquí" on the nearest
/// station, facility alerts inline in grey, the live trains drawn on the rail,
/// and ONE service card per affected run at the top.
///
/// Mode, line and direction selection moved to the bottom accessory (T1): this
/// screen carries no top header any more — only the status capsule
/// (`FreshnessChip`, styled there) and the sticky termini header of the
/// timeline.
@MainActor
struct DiagramScreen: View {
    @EnvironmentObject private var app: AppModel
    /// The same persisted selection as the metro map, so the map and the
    /// timeline always show the same line (spec S4).
    @AppStorage("metroSelectedLine") private var selectedLineCode = MetroLine.allLines[0].code
    @State private var lineState: LineState?
    @State private var selectedStation: Station?
    /// Whether the collapsed service-alert summary is expanded (#91): five
    /// cards pushed the timeline below the fold, so several alerts collapse
    /// into one row.
    @State private var showsServiceCards = false
    /// Heights the rows report once rendered (`ParadesRowHeightProbe`): the
    /// train overlay places the trains from these, so a row that grew past
    /// its planned minimum (large Dynamic Type) keeps its trains on the rail
    /// dots. Cleared per line so values of the previous line never leak into
    /// the new one.
    @State private var measuredRowHeights: [Int: CGFloat] = [:]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var selectedLine: MetroLine {
        MetroLine.line(forCode: selectedLineCode) ?? MetroLine.allLines[0]
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                statusCapsule
                content
            }
            // The bottom accessory (T1) names the mode; the screen keeps no
            // title bar of its own any more (spec S5).
            // The icon's network behind the top, fading out before the rows
            // (spec S11, mockup `V5Metro`).
            .networkHeaderBackground(opacity: 0.45)
            .navigationBarHidden(true)
            // Same rule as MapScreen: the loader task lives on the always-
            // visible container, not on the view that requires loaded data.
            .task(id: selectedLineCode) {
                // A new line starts with its alert summary collapsed (#91).
                showsServiceCards = false
                measuredRowHeights = [:]
                // The interchange badges read the places catalog (fix F1); a
                // disk read, no request, when nothing has loaded it yet.
                if PlaceCatalogStore.shared.places.isEmpty {
                    PlaceCatalogStore.shared.loadFromCache()
                }
                guard let client = app.client else { return }
                let state = LineState(line: selectedLine, client: client)
                self.lineState = state
                await state.run()
            }
        }
        // Same as MapScreen: the sheet comes from the stack itself and its
        // detents are declared here, not inside the presented view.
        .sheet(item: $selectedStation) { station in
            StationDetailView(station: station, line: selectedLine)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    /// The status capsule, top-left over the content (spec S2): the existing
    /// `FreshnessChip` initializer, restyled by T1 — this screen only calls it.
    @ViewBuilder
    private var statusCapsule: some View {
        Group {
            if let state = lineState {
                FreshnessChip(lineState: state)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var content: some View {
        if let message = app.missingCredentialsMessage {
            ConfigurationNotice(message: message)
        } else if let state = lineState {
            timeline(state: state)
        } else {
            ProgressView("Carregant…")
        }
    }

    @ViewBuilder
    private func timeline(state: LineState) -> some View {
        let incidents = IncidentIndex.incidents(
            for: app.alerts,
            stations: state.stations,
            lineCode: selectedLine.code
        )
        let affectedCodes = Set(incidents.keys.filter { !(incidents[$0] ?? []).isEmpty })
        let termini = ParadesTimeline.metroTerminiNames(in: state.stations)
        let cards = Self.serviceCards(
            alerts: app.alerts,
            cardAlertIDs: ParadesTimeline.serviceCardAlertIDs(
                stations: state.stations,
                incidents: incidents
            )
        )
        let stationRows = Self.rowPlan(
            stations: state.stations,
            incidents: incidents,
            state: state,
            places: PlaceCatalogStore.shared.places
        )
        let nearest = ParadesTimeline.nearestStation(
            stations: state.stations,
            userLocation: LocationService.shared.location
        )
        ScrollView {
            VStack(spacing: 0) {
                serviceCardsSection(cards)
                if state.isFeedEmpty {
                    // No arrivals feed for this line: say so above the rows
                    // instead of leaving a rail with no trains (spec S8).
                    NoRealtimeDataCard(theoretical: state.isTheoretical)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                }
                TerminiHeader(termini: termini, lineColorHex: selectedLine.colorHex)
                    .padding(.top, cards.isEmpty && state.isFeedEmpty ? 8 : 12)
                rowsColumn(
                    state: state,
                    rows: stationRows,
                    affectedCodes: affectedCodes,
                    nearest: nearest
                )
                .padding(.top, 4)
                .padding(.bottom, 16)
            }
        }
        .refreshable {
            await state.pollArrivals()
        }
    }

    /// The station rows plus the trains, sharing one frame: the overlay is
    /// attached to the rows themselves, so its origin is the top of the first
    /// row and a train can never drift away from the rows it is drawn over.
    private func rowsColumn(
        state: LineState,
        rows: [ParadesStationRow],
        affectedCodes: Set<Int>,
        nearest: (station: Station, distanceMeters: Double)?
    ) -> some View {
        VStack(spacing: 0) {
            ForEach(rows) { row in
                ParadesMetroRow(
                    row: row,
                    line: selectedLine,
                    interchangeCodes: row.interchangeCodes,
                    isNearest: nearest?.station.code == row.station.code,
                    hereText: nearest?.station.code == row.station.code
                        ? ParadesTimeline.hereText(distanceMeters: nearest!.distanceMeters)
                        : nil,
                    edgeAffected: ParadesTimeline.isEdgeAffected(
                        fromStationCode: row.station.code,
                        nextStationCode: row.nextStationCode,
                        affectedCodes: affectedCodes
                    )
                )
                .onTapGesture { selectedStation = row.station }
            }
        }
        // The rows report their rendered heights upward, and the overlay
        // below reads the same measurements: both always agree on where a
        // row starts and ends, even when it grew past its planned minimum.
        .onPreferenceChange(ParadesRowHeightKey.self) { measuredRowHeights = $0 }
        .overlay(alignment: .topLeading) {
            TrainOverlay(state: state, line: selectedLine, rows: rows, measuredHeights: measuredRowHeights)
                .allowsHitTesting(false)
        }
    }

    /// The alert behind each service card id, resolved once so the cards and
    /// the dotted rail read the same feed (S8: one source).
    private static func serviceCards(
        alerts: [ServiceAlert],
        cardAlertIDs: [String]
    ) -> [ServiceAlert] {
        let byID = Dictionary(alerts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return cardAlertIDs.compactMap { byID[$0] }
    }

    /// The top of the timeline (spec S8): one card per affected run, or —
    /// when several runs are affected — one summary row that expands on tap,
    /// because a stack of truncated cards filled the top half of the screen
    /// and pushed the timeline below the fold (#91).
    @ViewBuilder
    private func serviceCardsSection(_ cards: [ServiceAlert]) -> some View {
        if cards.count > 1 {
            Button {
                withAnimation(AppMotion.smooth(reduceMotion: reduceMotion)) {
                    showsServiceCards.toggle()
                }
            } label: {
                HStack(spacing: 12) {
                    Image("icon-alert")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 22, height: 22)
                        .foregroundStyle(Color(hex: "FF9F0A"))
                    Text("\(cards.count) avisos a \(selectedLine.displayName)")
                        .font(.subheadline.weight(.bold))
                    Spacer(minLength: 0)
                    Image(systemName: showsServiceCards ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 20)
                        .fill(Color(hex: "FF9F0A").opacity(0.14))
                        .overlay(
                            RoundedRectangle(cornerRadius: 20)
                                .strokeBorder(Color(hex: "FF9F0A").opacity(0.45), lineWidth: 1)
                        )
                )
            }
            .buttonStyle(.plain)
            .accessibilityHint("Mostra o amaga la llista d'avisos")
            .accessibilityValue(showsServiceCards ? "Desplegat" : "Plegat")
            .padding(.horizontal, 16)
            .padding(.top, 8)
            if showsServiceCards {
                ForEach(cards) { card in
                    ServiceCard(alert: card)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                }
            }
        } else if let card = cards.first {
            ServiceCard(alert: card)
                .padding(.horizontal, 16)
                .padding(.top, 8)
        }
    }

    /// One entry per station, in line order, with the incidents, the
    /// interchange badges and the direction columns it shows. The overlay
    /// reads the same plan the rows are drawn from, so both agree on every
    /// row's height.
    private static func rowPlan(
        stations: [Station],
        incidents: [Int: [StationIncident]],
        state: LineState,
        places: [Place]
    ) -> [ParadesStationRow] {
        stations.enumerated().map { index, station in
            ParadesStationRow(
                index: index,
                station: station,
                nextStationCode: index + 1 < stations.count ? stations[index + 1].code : nil,
                incidents: incidents[station.code] ?? [],
                columnVia1: ParadesTimeline.metroColumn(
                    arrivals: state.arrivalsByStop[station.code] ?? [],
                    via: 1
                ),
                columnVia2: ParadesTimeline.metroColumn(
                    arrivals: state.arrivalsByStop[station.code] ?? [],
                    via: 2
                ),
                // The same rule the metro map draws its interchange capsules
                // with (one rule for both screens).
                interchangeCodes: StationInterchange.metroLineDisplayNames(
                    for: station,
                    places: places,
                    lineCode: state.line.code
                )
            )
        }
    }
}

/// One station row of the metro timeline (spec S8, mockup `V4Metro`).
private struct ParadesStationRow: Identifiable {
    /// The row's position in the line: the identity the rows are rendered by.
    /// A station code is not unique enough to key on (a line can list the same
    /// station twice), the index always is.
    let index: Int
    let station: Station
    /// Station code of the next row, or nil on the last one: the rail's
    /// dotted-edge rule needs both ends of the edge.
    let nextStationCode: Int?
    /// Facility and service incidents of the station, in alert order.
    let incidents: [StationIncident]
    /// The two tabular time columns: via 1 (down, toward the last station)
    /// and via 2 (up, toward the first), as the old pills chose them.
    let columnVia1: ParadesTimeText
    let columnVia2: ParadesTimeText
    /// Metro–metro interchange badges (D4), display names in line order.
    let interchangeCodes: [String]

    var id: Int { index }

    /// Planned minimum height of the row (`ParadesMetroRow.baseHeight`): a
    /// row whose content needs more room grows past it, and the train
    /// overlay learns the real height through `ParadesRowHeightKey`.
    var height: CGFloat { ParadesMetroRow.baseHeight }
}

/// The sticky direction header (spec S8): each terminus named once, over its
/// own time column, on a glass strip.
private struct TerminiHeader: View {
    /// First and last station name, nil while the line has no stations.
    let termini: (first: String, last: String)?
    let lineColorHex: String

    var body: some View {
        HStack {
            Spacer(minLength: 8)
            if let termini {
                // The last station (via 1, the down direction) sits over the
                // first time column, the first station over the second.
                Text("↓ \(termini.last)")
                Text("↑ \(termini.first)")
            }
        }
        .font(.caption.weight(.bold))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.trailing, 12)
        .padding(.vertical, 8)
        .background(.thinMaterial)
        .overlay(alignment: .leading) {
            Circle()
                .fill(Color(hex: lineColorHex))
                .frame(width: 8, height: 8)
                .padding(.leading, 16)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            termini.map { "Cap a \($0.last) i cap a \($0.first)" } ?? "Direccions de la línia"
        )
    }
}

/// One station row of the metro timeline: station marker on the rail, name
/// with its interchange badges and inline facility alerts, and the two
/// right-aligned tabular time columns.
private struct ParadesMetroRow: View {
    let row: ParadesStationRow
    let line: MetroLine
    let interchangeCodes: [String]
    /// Whether "Ets aquí · <distance>" is drawn on this row.
    let isNearest: Bool
    let hereText: String?
    /// Whether the rail edge leaving this station is dotted (affected run).
    let edgeAffected: Bool

    static let baseHeight: CGFloat = 64
    static let horizontalPadding: CGFloat = 16
    static let markerSize: CGFloat = 26
    static let railWidth: CGFloat = 5

    static var railCenterX: CGFloat { horizontalPadding + markerSize / 2 }

    private var incidents: [StationIncident] { row.incidents }
    /// Facility alerts inline in grey (spec S7, S8); service alerts are told
    /// by the top cards and the dotted rail instead.
    private var facilityIncidents: [StationIncident] {
        incidents.filter { ParadesTimeline.isFacilityIncident($0) }
    }
    private var lineColor: Color { Color(hex: line.colorHex) }

    var body: some View {
        content
            .padding(.leading, Self.horizontalPadding + Self.markerSize + 12)
            .padding(.trailing, Self.horizontalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            // A row grows with its content (the FGC rows' pattern):
            // `baseHeight` is only the minimum, so a wrapped name or a larger
            // Dynamic Type never clips the third content line, and the rail
            // overlay below re-anchors the marker to the row's real center.
            .frame(minHeight: row.height)
            .background(isNearest ? Color(hex: "409CFF").opacity(0.12) : Color.clear)
            .overlay(alignment: .topLeading) { railColumn }
            .background { ParadesRowHeightProbe(index: row.index) }
            .contentShape(Rectangle())
    }

    private var content: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(row.station.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                if !interchangeCodes.isEmpty {
                    badgesRow
                }
                if let hereText {
                    hereLabel(text: hereText)
                }
                ForEach(facilityIncidents) { incident in
                    facilityLine(incident)
                }
            }
            Spacer(minLength: 8)
            // The widths the columns ever need ("<1 min", "59 min") instead of
            // the old generous ones, so the station name takes the free width
            // instead of truncating with a gap before the times (#91).
            timeColumn(row.columnVia1, width: 58)
            timeColumn(row.columnVia2, width: 66)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    /// Metro–metro interchange capsules (D4): white capsule, dark ink, the
    /// line's own colour only naming it. Plain shapes over the mockup's look.
    private var badgesRow: some View {
        HStack(spacing: 6) {
            ForEach(interchangeCodes, id: \.self) { code in
                Text(code)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color(hex: "1C1C1E"))
                    .padding(.horizontal, 5)
                    .frame(minWidth: 24, minHeight: 18)
                    .background(Capsule().fill(.white))
                    .accessibilityLabel("Correspondència amb \(code)")
            }
        }
    }

    /// "Ets aquí · 250 m" on the row nearest to the rider (spec S8).
    private func hereLabel(text: String) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(Color(hex: "409CFF"))
                .frame(width: 8, height: 8)
                .shadow(color: Color(hex: "409CFF").opacity(0.3), radius: 3)
            Text(text)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color(hex: "409CFF"))
        }
    }

    /// A facility alert inline in grey with its existing icon (spec S8).
    private func facilityLine(_ incident: StationIncident) -> some View {
        HStack(spacing: 5) {
            Image(incident.kind.incidentIconAssetName)
                .resizable()
                .scaledToFit()
                .frame(width: 12, height: 12)
                .foregroundStyle(.secondary)
            Text(incident.title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    /// One tabular time column: "ara" in green, "—" and countdowns in the
    /// row's default colour (spec S8, mockup colors).
    private func timeColumn(_ text: ParadesTimeText, width: CGFloat) -> some View {
        Text(text.text)
            .font(.callout.weight(.bold))
            .monospacedDigit()
            .foregroundStyle(text.isImminent ? Color(hex: "30D158") : Color.primary)
            .frame(width: width, alignment: .trailing)
            .accessibilityLabel(text.text)
    }

    private var accessibilityText: String {
        var parts: [String] = [row.station.name]
        if let hereText {
            parts.append(hereText)
        }
        for direction in [row.columnVia1, row.columnVia2] {
            switch direction {
            case .now: parts.append("ara")
            case .minutes(let text): parts.append("en \(text)")
            case .none: break
            }
        }
        if !facilityIncidents.isEmpty {
            parts.append(facilityIncidents.map(\.title).joined(separator: ", "))
        }
        return parts.joined(separator: ", ")
    }

    // MARK: - Rail

    /// The rail through the whole row and the hollow station marker centered
    /// on it, measured against the row's REAL height (the whole-row overlay
    /// pattern the FGC rows use): the marker sits at the center the row's
    /// content is centered on, and the rail still runs from it down to the
    /// row's bottom edge, where the neighbour's own segment starts. At the
    /// default text size the row is exactly `baseHeight`, so nothing moves.
    private var railColumn: some View {
        GeometryReader { geo in
            railColumn(height: geo.size.height)
                .allowsHitTesting(false)
        }
    }

    private func railColumn(height: CGFloat) -> some View {
        let markerCenterY = height / 2
        return ZStack(alignment: .top) {
            Color.clear
                .frame(width: Self.markerSize, height: height)
            // The edge below the marker: solid, or dotted on an affected run.
            if edgeAffected {
                DottedRail()
                    .stroke(lineColor, style: StrokeStyle(lineWidth: Self.railWidth, lineCap: .round, dash: [0.1, 8]))
                    .frame(width: Self.railWidth, height: max(height - markerCenterY, 0))
                    .offset(y: markerCenterY)
            } else {
                Rectangle()
                    .fill(lineColor)
                    .frame(width: Self.railWidth, height: max(height - markerCenterY, 0))
                    .offset(y: markerCenterY)
            }
            marker
                .padding(.top, markerCenterY - Self.markerSize / 2)
        }
        .frame(width: Self.markerSize, height: height, alignment: .top)
        .padding(.leading, Self.horizontalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Hollow station dot (S6): white fill, line-coloured ring; the two ends
    /// of the line are indistinguishable here because the termini header names
    /// them once at the top.
    private var marker: some View {
        Circle()
            .fill(Color.white)
            .frame(width: Self.markerSize * 0.6, height: Self.markerSize * 0.6)
            .overlay(
                Circle().stroke(lineColor, lineWidth: 3)
            )
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
            .foregroundStyle(Color(hex: "F59E0B"))
            .padding(2)
            .background(Circle().fill(.white))
            .offset(x: 3, y: 3)
    }
}

/// The dotted stroke of one affected edge: a vertical line whose dash pattern
/// renders as dots (`0.1 9` with round caps, the mockup's own values).
private struct DottedRail: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        return path
    }
}

/// Measured height of the Parades rows, keyed by row index: each row reports
/// its rendered height, so the vehicle overlays compute their positions from
/// the real layout instead of the planned minimum. Internal because the bus
/// timeline (`BusDiagramScreen.swift`) shares it.
struct ParadesRowHeightKey: PreferenceKey {
    static var defaultValue: [Int: CGFloat] { [:] }
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

/// The one-row probe that feeds `ParadesRowHeightKey`: a background
/// GeometryReader measures the row without influencing its layout.
struct ParadesRowHeightProbe: View {
    let index: Int

    var body: some View {
        GeometryReader { geo in
            Color.clear.preference(key: ParadesRowHeightKey.self, value: [index: geo.size.height])
        }
    }
}

/// Pure layout math of the Parades timelines, shared by the metro and bus
/// screens: the rows' cumulative tops and the y of a vehicle marker, always
/// computed from the same numbers the rows render with, so rows and vehicles
/// cannot drift apart when a row grows past its planned minimum.
enum ParadesRowGeometry {
    /// Height of one row: the height measured on screen when known, else the
    /// planned minimum.
    static func rowHeight(planned: CGFloat, measured: CGFloat?) -> CGFloat {
        measured ?? planned
    }

    /// Cumulative top of every row, from the planned minima and the heights
    /// measured on screen (row index → measured height). A measured height
    /// wins: the neighbours sit at the grown row's real edges.
    static func tops(planned: [CGFloat], measured: [Int: CGFloat]) -> [CGFloat] {
        var result: [CGFloat] = []
        result.reserveCapacity(planned.count)
        var top: CGFloat = 0
        for (index, plannedHeight) in planned.enumerated() {
            result.append(top)
            top += rowHeight(planned: plannedHeight, measured: measured[index])
        }
        return result
    }

    /// Y of a vehicle at the fractional row index `position`: the top of its
    /// row, plus the fraction of that row's real height, plus half the height
    /// — the marker center of the row it lands on. The index is clamped into
    /// the row range first, so the fraction always stays inside one row and
    /// the last stop maps to its own marker instead of one row past it.
    static func vehicleY(tops: [CGFloat], heights: [CGFloat], position: Double) -> CGFloat? {
        guard let last = heights.indices.last else { return nil }
        let clamped = min(max(position, 0), Double(last))
        let lower = Int(clamped)
        let fraction = clamped - Double(lower)
        let height = heights[lower]
        return tops[lower] + CGFloat(fraction) * height + height / 2
    }
}

/// ONE service card per affected run at the top of the timeline (spec S8):
/// amber, the alert title and its start time.
private struct ServiceCard: View, Identifiable {
    let alert: ServiceAlert

    var id: String { alert.id }

    var body: some View {
        HStack(spacing: 12) {
            Image("icon-alert")
                .resizable()
                .scaledToFit()
                .frame(width: 22, height: 22)
                .foregroundStyle(Color(hex: "FF9F0A"))
            VStack(alignment: .leading, spacing: 2) {
                Text(alertTitle)
                    .font(.subheadline.weight(.bold))
                    .lineLimit(1)
                Text(alertTime)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(hex: "FF9F0A").opacity(0.14))
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .strokeBorder(Color(hex: "FF9F0A").opacity(0.45), lineWidth: 1)
                )
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(alertTitle). \(alertTime)")
    }

    /// Title of the card: the kind wording the station rows use, or the plain
    /// text's first sentence for the line-wide effects.
    private var alertTitle: String {
        let text = alert.text?.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
        if let text, !text.isEmpty {
            let sentence = text.split(separator: ".", maxSplits: 1).first.map(String.init) ?? text
            return sentence.count > 80 ? String(sentence.prefix(80)) + "…" : sentence
        }
        return "Servei afectat"
    }

    /// "des de les 10:42" from the alert's begin date, or nothing usable.
    private var alertTime: String {
        guard let begin = alert.beginDate else { return "Ara mateix" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return "des de les \(formatter.string(from: begin))"
    }
}

/// A vehicle placed in the timeline: its y already comes from the rows'
/// real heights.
private struct DiagramTrain: Identifiable {
    let id: String
    let colorHex: String
    let heading: Double
    let isEstimated: Bool
    let y: CGFloat
}

/// Draws the live trains ON the rail with the S6 vehicle marker (spec S8). It
/// shares the rows' coordinate space through the overlay it is attached to:
/// every y is measured from the top of the first row, so rows and trains
/// cannot drift apart.
@MainActor
private struct TrainOverlay: View {
    let state: LineState
    let line: MetroLine
    let rows: [ParadesStationRow]
    /// Heights measured on screen (`ParadesRowHeightProbe`): the trains are
    /// placed from the real rows, so a row that grew past its minimum keeps
    /// its trains on the dots. Falls back to the planned minimum per row
    /// until the measurement lands.
    let measuredHeights: [Int: CGFloat]

    var body: some View {
        let trains = trainPlacements()
        // A ZStack so each `.position` is measured from the top-leading corner
        // of the rows' frame, the one coordinate space the overlay shares with
        // them.
        ZStack(alignment: .topLeading) {
            ForEach(trains) { train in
                VehicleMarkerView(
                    colorHex: train.colorHex,
                    glyph: .train,
                    headingDegrees: train.heading,
                    isEstimated: train.isEstimated,
                    isSelected: false,
                    size: 30
                )
                .position(x: ParadesMetroRow.railCenterX, y: train.y)
            }
        }
    }

    private func trainPlacements() -> [DiagramTrain] {
        guard let engine = state.engine, !rows.isEmpty else { return [] }
        // Cumulative top of every row and each row's real height, taken from
        // the same numbers the rows render with: a fractional index therefore
        // lands on the right pixel even when a row grew past its minimum.
        let planned = rows.map(\.height)
        let tops = ParadesRowGeometry.tops(planned: planned, measured: measuredHeights)
        let heights = planned.enumerated().map { index, plannedHeight in
            ParadesRowGeometry.rowHeight(planned: plannedHeight, measured: measuredHeights[index])
        }
        return state.positions.map { position in
            // The engine index is clamped to the station range first: the
            // fractional part is then always inside the row it belongs to, so
            // the last station maps to its own marker instead of one row past
            // it (S2, S6).
            let rawIndex = engine.stationIndexPosition(atRouteDistance: position.routeDistance)
            let y = ParadesRowGeometry.vehicleY(tops: tops, heights: heights, position: rawIndex) ?? 0
            let trainLine = MetroLine.line(forCode: position.lineCode) ?? line
            return DiagramTrain(
                id: position.id,
                colorHex: trainLine.colorHex,
                // Schematic rail: forward runs down it, like the bus diagram.
                heading: position.forward ? 180 : 0,
                isEstimated: position.isTheoretical,
                y: y
            )
        }
    }
}
