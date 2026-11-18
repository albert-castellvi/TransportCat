import SwiftUI

/// Parades, Rodalies: the stations of the selected line as a timeline in the
/// line colour, one time column per direction (the next departure of the
/// timetable, with Renfe's realtime delay when the feed has it) and the live
/// trains drawn on the rail where the feed places them.
///
/// The timeline lives in an opaque card (spec B.3), so the network motif only
/// decorates the header band above it: `#1C1D21`, radius 22, 16 pt side
/// margins, 10 pt below the freshness chip. The header moved to the bottom
/// accessory, as on every mode: this screen keeps only the status capsule.
@MainActor
struct RodaliesLinesScreen: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(RodaliesLineSelection.storageKey)
    private var selectedLineCode = RodaliesLineSelection.defaultLineCode
    /// Stations of the shown line in travel order.
    @State private var stations: [RodaliesStation] = []
    /// Next departure per station and direction, rebuilt by the 30 s loop so a
    /// 10 Hz marker update never re-reads the timetable.
    @State private var departures: [String: [Int: RodaliesDeparture]] = [:]
    /// The clock the countdowns are drawn against; advanced by the same loop.
    @State private var now = Date()
    @State private var selectedPlace: Place?
    @State private var selectedTrain: RodaliesLiveTrain?
    /// The N trains behind a row's "+N" pill, listed in the grouped sheet.
    @State private var selectedTrainGroup: RodaliesTrainGroupSelection?

    /// Refresh period of the time columns: the same 30 s as the feeds.
    private static let refreshIntervalNanoseconds: UInt64 = 30_000_000_000
    /// Height of the motif band above the card; the card hides it below this
    /// line, so it can never run behind the rows.
    private static let motifBandHeight: CGFloat = 120

    init() {}

    private var state: RodaliesNetworkState { RodaliesNetworkState.shared }

    private var shownLineCode: String {
        RodaliesLineSelection.resolve(selected: selectedLineCode, from: state.lines)
    }

    private var shownLine: RodaliesLine? {
        state.lines.first { $0.code == shownLineCode }
    }

    private var timeZone: TimeZone {
        state.schedule.map(RodaliesDepartures.timeZone(of:)) ?? .current
    }

    /// The two directions of the line, in direction order (0 forward).
    private var shownDirections: [RodaliesDirection] {
        state.directions(ofLine: shownLineCode)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                statusCapsule
                content
            }
            // The motif is its own top band and ends before the rows (B.3):
            // the card below is opaque, so the art never crosses a name.
            .background(alignment: .top) { headerMotif }
            .navigationBarHidden(true)
            .sensoryFeedback(.selection, trigger: selectedLineCode)
            .onAppear {
                if state.lines.isEmpty { state.loadTopology() }
                refreshStations()
            }
            .onChange(of: selectedLineCode) { _, _ in
                departures = [:]
                refreshStations()
            }
            .onChange(of: state.lineLayers.count) { _, _ in refreshStations() }
            .onChange(of: state.scheduleLoadedAt) { _, _ in refreshDepartures() }
        }
        .task {
            // The timetable is what the time columns read; the loop keeps them
            // ageing and retries a failed read without leaving the tab.
            while !Task.isCancelled {
                if state.schedule == nil {
                    await state.loadSchedule()
                }
                refreshDepartures()
                do {
                    try await Task.sleep(nanoseconds: Self.refreshIntervalNanoseconds)
                } catch {
                    return
                }
            }
        }
        .sheet(item: $selectedTrain) { train in
            RodaliesTrainSheet(
                vehicleID: RodaliesNetworkState.vehicleID(for: train.id),
                followingVehicleID: .constant(nil)
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $selectedTrainGroup) { group in
            RodaliesGroupedTrainsSheet(
                stationName: group.stationName,
                trains: group.trains
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $selectedPlace) { place in
            RodaliesStationSheet(place: place)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    /// The status capsule, top-left: the existing `FreshnessChip` with the
    /// values of this mode's poll.
    @ViewBuilder
    private var statusCapsule: some View {
        Group {
            if hasLiveSignal {
                FreshnessChip(
                    updatedAt: state.arrivalsUpdatedAt,
                    lastAttemptFailed: state.lastPollFailed,
                    feedEmpty: false
                )
                .transition(AppMotion.chipTransition)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .animation(AppMotion.smooth(reduceMotion: reduceMotion), value: hasLiveSignal)
    }

    private var hasLiveSignal: Bool {
        state.arrivalsUpdatedAt != nil || state.lastPollFailed
    }

    // MARK: - Motif

    /// The app-icon network on a ~120 pt top band, fading to black before the
    /// card starts. The card is opaque, so nothing of the motif reaches a row.
    private var headerMotif: some View {
        NetworkArt(.header, opacity: 0.45)
            .frame(height: NetworkArtGeometry.designHeight)
            .frame(height: Self.motifBandHeight, alignment: .top)
            .clipped()
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .white, location: 0),
                        .init(color: .white.opacity(0.7), location: 0.55),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(maxWidth: .infinity, alignment: .top)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let line = shownLine {
            stationsList(line: line)
        } else if let message = state.errorMessage {
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

    /// The whole list in one opaque card: the direction band, the timetable
    /// error card when it applies, and the station rows with their separators.
    private func stationsList(line: RodaliesLine) -> some View {
        let trainsByStation = Self.trainsByStation(in: state.trains, lineCode: line.code)
        let directionColumns = shownDirections.map(\.direction)
        let directionLabels = RodaliesDirectionLabels.labels(
            names: directionNames,
            order: directionColumns
        )
        let nearest = ParadesTimeline.nearestStation(
            stations: stations,
            userLocation: LocationService.shared.location
        )
        return ScrollView {
            VStack(spacing: 0) {
                if !directionLabels.isEmpty {
                    directionBand(labels: directionLabels, lineColorHex: line.colorHex)
                }
                if state.schedule == nil {
                    scheduleUnavailableCard
                }
                if stations.isEmpty {
                    Text("Cap estació publicada per a aquesta línia.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(24)
                        .frame(maxWidth: .infinity)
                }
                ForEach(Array(stations.enumerated()), id: \.element.id) { index, station in
                    let stationTrains = trainsByStation[station.id] ?? []
                    let isNearest = nearest?.station.id == station.id
                    RodaliesLinesRow(
                        station: station,
                        shownLineCode: line.code,
                        isFirst: index == 0,
                        isLast: index == stations.count - 1,
                        lineColorHex: line.colorHex,
                        departures: departures[station.id] ?? [:],
                        directionColumns: directionColumns,
                        directionNames: directionNames,
                        scheduleAvailable: state.schedule != nil,
                        trains: stationTrains,
                        markerIsEstimated: stationTrains.first.map {
                            state.isEstimated(vehicleID: $0.id)
                        } ?? false,
                        timeZone: timeZone,
                        now: now,
                        hereText: isNearest
                            ? ParadesTimeline.hereText(distanceMeters: nearest!.distanceMeters)
                            : nil,
                        onTapStation: { selectedPlace = RodaliesPlaces.place(for: station) },
                        onTapTrain: { train in selectedTrain = train },
                        onTapGroupedTrains: {
                            selectedTrainGroup = RodaliesTrainGroupSelection(
                                stationID: station.id,
                                stationName: station.name,
                                trains: stationTrains
                            )
                        }
                    )
                    .overlay(alignment: .bottom) {
                        // Hairline on the row itself, not between rows: the
                        // rail of two neighbours still meets at the boundary.
                        if index < stations.count - 1 {
                            Rectangle()
                                .fill(Color.white.opacity(0.06))
                                .frame(height: 1)
                                .padding(.leading, RodaliesLinesRow.contentLeading)
                                .padding(.trailing, RodaliesLinesRow.horizontalPadding)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 16)
        }
        .background(RoundedRectangle(cornerRadius: 22).fill(Color(hex: "1C1D21")))
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    /// The direction band inside the card (B.3): the line's colour dot and the
    /// two termini with their arrows, on an opaque `#24252A` strip whose top
    /// corners are the card's own 22 pt.
    private func directionBand(
        labels: [RodaliesDirectionLabel],
        lineColorHex: String
    ) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color(hex: lineColorHex))
                .frame(width: 8, height: 8)
            Spacer(minLength: 8)
            ForEach(labels) { label in
                bandLabel(label)
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .frame(height: 34)
        .background(Color(hex: "24252A"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(bandAccessibilityLabel(labels))
    }

    /// "↓ Maçanet-Massanes": the arrow follows the direction, the name is the
    /// full terminus or its short form when the pair would not fit.
    @ViewBuilder
    private func bandLabel(_ label: RodaliesDirectionLabel) -> some View {
        Group {
            if label.direction == 0 {
                Text("↓ \(label.name)")
            } else {
                Text("↑ \(label.name)")
            }
        }
        .font(.caption.weight(.bold))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.75)
    }

    private func bandAccessibilityLabel(_ labels: [RodaliesDirectionLabel]) -> String {
        switch labels.count {
        case 0:
            return String(localized: "Direccions de la línia")
        case 1:
            return String(localized: "Cap a \(labels[0].name)")
        default:
            return String(localized: "Cap a \(labels[0].name) i cap a \(labels[1].name)")
        }
    }

    /// The failed-read card: the station sheet's wording and retry, shown once
    /// instead of an "—" in every column. While the pack is still loading the
    /// card says so; a read that actually failed offers the button.
    @ViewBuilder
    private var scheduleUnavailableCard: some View {
        if state.isLoadingSchedule || !state.scheduleLoadFailed {
            HStack(spacing: 10) {
                ProgressView()
                Text("Carregant els horaris…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Label(
                    "No s'han pogut carregar els horaris de Rodalies.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                Button("Torna-ho a provar") {
                    retrySchedule()
                }
                .disabled(state.isLoadingSchedule)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(hex: "24252A")))
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    private func retrySchedule() {
        Task {
            await state.loadSchedule()
            refreshDepartures()
        }
    }

    /// Destination of each direction: the last station of its travel order.
    private var directionNames: [Int: String] {
        var names: [Int: String] = [:]
        for direction in shownDirections {
            if let last = direction.stationIDs.last,
               let station = state.topology?.station(id: last) {
                names[direction.direction] = station.name
            }
        }
        return names
    }

    private func refreshStations() {
        stations = state.stations(ofLine: shownLineCode)
        refreshDepartures()
    }

    /// Recomputes the two time columns of every station at `now`.
    private func refreshDepartures() {
        now = Date()
        guard state.schedule != nil else {
            departures = [:]
            return
        }
        var next: [String: [Int: RodaliesDeparture]] = [:]
        next.reserveCapacity(stations.count)
        for station in stations {
            let board = state.nextDepartures(stationID: station.id, now: now, limit: 20)
            var perDirection: [Int: RodaliesDeparture] = [:]
            for departure in board where perDirection[departure.direction] == nil {
                perDirection[departure.direction] = departure
            }
            next[station.id] = perDirection
        }
        departures = next
    }

    /// Live trains of the shown line keyed by the station the feed places them
    /// at: the stop they are at or leaving, else the next one they announce.
    /// Codes the timeline does not contain are never read. T2 owns the
    /// semantics; the list consumes this mapping as it is.
    private static func trainsByStation(
        in trains: [RodaliesLiveTrain],
        lineCode: String
    ) -> [String: [RodaliesLiveTrain]] {
        var result: [String: [RodaliesLiveTrain]] = [:]
        for train in trains where train.lineCode == lineCode {
            guard let stopID = train.currentStopID ?? train.nextStopID else { continue }
            result[stopID, default: []].append(train)
        }
        return result
    }
}

/// The item of the grouped-trains sheet: the station and the trains the feed
/// places there. Identified by the station so reopening the pill is stable.
private struct RodaliesTrainGroupSelection: Identifiable {
    let stationID: String
    let stationName: String
    let trains: [RodaliesLiveTrain]

    var id: String { stationID }
}

/// One station row of the Rodalies timeline (B.3): a 64 pt row with the rail
/// in the line colour, a 26 pt marker column, the station name with its other
/// line capsules, and one time column per direction. A train replaces the
/// hollow station dot with the filled 22 pt marker; several trains at one stop
/// fold into that one marker plus a "+N" pill that opens their list.
private struct RodaliesLinesRow: View {
    let station: RodaliesStation
    let shownLineCode: String
    let isFirst: Bool
    let isLast: Bool
    let lineColorHex: String
    let departures: [Int: RodaliesDeparture]
    let directionColumns: [Int]
    let directionNames: [Int: String]
    let scheduleAvailable: Bool
    let trains: [RodaliesLiveTrain]
    /// Whether the row's single train marker is an estimate (stop coordinate or
    /// timetable/ETA interpolation) and must draw the dashed ring.
    let markerIsEstimated: Bool
    let timeZone: TimeZone
    let now: Date
    let hereText: String?
    let onTapStation: () -> Void
    let onTapTrain: (RodaliesLiveTrain) -> Void
    let onTapGroupedTrains: () -> Void

    static let horizontalPadding: CGFloat = 16
    static let markerSize: CGFloat = 26
    static let railWidth: CGFloat = 5
    /// Name and badges start here inside the card: 16 + 26 + 12.
    static let contentLeading: CGFloat = 16 + 26 + 12
    static let rowMinHeight: CGFloat = 64
    /// The two time columns of the metro timeline, in direction order.
    static let timeColumnWidths: [CGFloat] = [58, 66]
    /// The train marker's touch target (44 pt) centered on the rail: the
    /// column starts 7 pt inside the card so its center is 7 + 22 = 29 pt, the
    /// same rail center supplied by `contentLeading`.
    static let touchColumnWidth: CGFloat = 44
    static let touchColumnLeading: CGFloat = 7
    static let railCenterInColumn: CGFloat = touchColumnWidth / 2

    private var lineColor: Color { Color(hex: lineColorHex) }

    var body: some View {
        let group = RodaliesStationTrains.group(trains)
        let badges = RodaliesStationBadges.badges(
            lineCodes: station.lineCodes,
            shownLineCode: shownLineCode
        )
        // The name and its "+N" pill share one group with a 6 pt gap, and
        // only then comes the 12 pt gap before the times: a station with
        // several trains still gives its name the width Metro gives it, so a
        // long name wraps instead of truncating ("Barcelona Plaça de
        // Catalunya").
        return HStack(alignment: .center, spacing: 0) {
            HStack(alignment: .center, spacing: 6) {
                Button(action: onTapStation) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(station.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.leading)
                            .lineLimit(2)
                            .minimumScaleFactor(0.9)
                        if !badges.isEmpty {
                            badgesRow(badges)
                        }
                        if let hereText {
                            hereLabel(hereText)
                        }
                        if scheduleAvailable && departures.isEmpty {
                            Text("Cap sortida prevista")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .contentShape(Rectangle())
                    .accessibilityElement(children: .ignore)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(accessibilityLabel(group: group))
                if group.count >= 2 {
                    Button {
                        onTapGroupedTrains()
                    } label: {
                        Text("+\(group.count)")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 6)
                            .frame(height: 16)
                            .background(
                                RoundedRectangle(cornerRadius: 8).fill(Color(hex: "2C2E34"))
                            )
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("rodalies-trains-pill")
                    .accessibilityLabel(trainCountText(group.count))
                    .accessibilityHint("Mostra la llista de trens")
                }
            }
            Spacer(minLength: 12)
            if scheduleAvailable {
                HStack(spacing: 12) {
                    ForEach(Array(directionColumns.enumerated()), id: \.element) { index, direction in
                        timeColumn(
                            direction,
                            width: Self.timeColumnWidths[min(index, Self.timeColumnWidths.count - 1)]
                        )
                    }
                }
            }
        }
        .padding(.leading, Self.contentLeading)
        .padding(.trailing, Self.horizontalPadding)
        .frame(minHeight: Self.rowMinHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hereText == nil ? Color.clear : Color(hex: "409CFF").opacity(0.12))
        .overlay(alignment: .topLeading) { railColumn(group: group) }
        .accessibilityElement(children: .contain)
    }

    // MARK: - Badges

    /// White capsules of the OTHER Rodalies lines that call here (B.3), at most
    /// three, then "+N". Decorative: the row label names every line.
    private func badgesRow(_ badges: RodaliesLineBadges) -> some View {
        HStack(spacing: 6) {
            ForEach(badges.codes, id: \.self) { code in
                RodaliesOtherLineBadge(text: code)
            }
            if badges.overflow > 0 {
                RodaliesOtherLineBadge(text: "+\(badges.overflow)")
            }
        }
        .accessibilityHidden(true)
    }

    /// "Ets aquí · 250 m", the same rule and blue as the metro row.
    private func hereLabel(_ text: String) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(Color(hex: "409CFF"))
                .frame(width: 8, height: 8)
            Text(text)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color(hex: "409CFF"))
        }
        .accessibilityHidden(true)
    }

    // MARK: - Times

    /// One direction's next departure: "ara" in green, "N min", the wall clock
    /// beyond an hour, or "—" when the direction has nothing ahead.
    @ViewBuilder
    private func timeColumn(_ direction: Int, width: CGFloat) -> some View {
        let time = departures[direction].map { departure in
            RodaliesDepartureText.time(
                until: departure.expectedAt,
                now: now,
                timeZone: timeZone
            )
        }
        if let time {
            Text(time.text)
                .font(.callout.weight(.bold).monospacedDigit())
                .foregroundStyle(time.isImminent ? Color(hex: "30D158") : Color.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: width, alignment: .trailing)
        } else {
            Text("—")
                .font(.callout.weight(.bold).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: width, alignment: .trailing)
        }
    }

    // MARK: - Rail

    /// The rail through the whole row with the station marker at its center.
    /// The rail runs to the row's center and the marker is drawn on top, so a
    /// row that grows with two-line names or badges never opens a gap at the
    /// dot. The 44 pt column keeps the train marker's full touch target inside
    /// the row while the visual rail stays at the card's 29 pt center.
    private func railColumn(group: RodaliesStationTrainGroup) -> some View {
        GeometryReader { geo in
            let height = geo.size.height
            let centerY = height / 2
            ZStack(alignment: .topLeading) {
                if !isFirst {
                    Rectangle()
                        .fill(lineColor)
                        .frame(width: Self.railWidth, height: max(centerY, 0))
                        .position(x: Self.railCenterInColumn, y: max(centerY, 0) / 2)
                }
                if !isLast {
                    Rectangle()
                        .fill(lineColor)
                        .frame(
                            width: Self.railWidth,
                            height: max(height - centerY, 0)
                        )
                        .position(
                            x: Self.railCenterInColumn,
                            y: centerY + max(height - centerY, 0) / 2
                        )
                }
                Group {
                    if let train = group.marker {
                        trainMarker(train)
                    } else {
                        stationMarker
                    }
                }
                .position(x: Self.railCenterInColumn, y: centerY)
            }
            .frame(width: Self.touchColumnWidth, height: height, alignment: .topLeading)
        }
        .frame(width: Self.touchColumnWidth)
        .padding(.leading, Self.touchColumnLeading)
    }

    /// Hollow station dot: white fill, line-coloured ring, the metro numbers.
    private var stationMarker: some View {
        Circle()
            .fill(Color.white)
            .frame(
                width: Self.markerSize * 0.6,
                height: Self.markerSize * 0.6
            )
            .overlay(Circle().stroke(lineColor, lineWidth: 3))
            .frame(width: Self.markerSize, height: Self.markerSize)
    }

    /// The single live-train marker of the row: the filled S6 circle with the
    /// tram glyph, centered on the station dot. Its 44 pt button keeps the
    /// minimum touch target while the visual marker stays at 22 pt.
    private func trainMarker(_ train: RodaliesLiveTrain) -> some View {
        Button {
            onTapTrain(train)
        } label: {
            VehicleMarkerView(
                colorHex: lineColorHex,
                glyph: .train,
                headingDegrees: nil,
                isEstimated: markerIsEstimated,
                isSelected: false,
                size: 22
            )
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(trainAccessibilityLabel(train))
    }

    // MARK: - Wording

    /// One combined label per row: station, interchange lines, every direction
    /// with its countdown, "Ets aquí", whether no departure is expected, and
    /// how many live trains the feed places here.
    private func accessibilityLabel(group: RodaliesStationTrainGroup) -> String {
        var parts = [String(localized: "Estació \(station.name)")]
        let allCodes = RodaliesStationBadges.badges(
            lineCodes: station.lineCodes,
            shownLineCode: shownLineCode,
            limit: 100
        ).codes
        if !allCodes.isEmpty {
            parts.append(
                String(localized: "Correspondència amb \(allCodes.joined(separator: ", "))")
            )
        }
        if let hereText {
            parts.append(hereText)
        }
        if scheduleAvailable {
            for direction in directionColumns {
                guard let departure = departures[direction] else { continue }
                let time = RodaliesDepartureText.time(
                    until: departure.expectedAt,
                    now: now,
                    timeZone: timeZone
                )
                let destination = directionNames[direction] ?? departure.headsign
                parts.append(String(localized: "Cap a \(destination): \(time.text)"))
            }
            if departures.isEmpty {
                parts.append(String(localized: "Cap sortida prevista"))
            }
        } else {
            parts.append(String(localized: "No s'han pogut carregar els horaris de Rodalies."))
        }
        if group.count > 0 {
            parts.append(trainCountText(group.count))
        }
        return parts.joined(separator: ". ")
    }

    private func trainCountText(_ count: Int) -> String {
        count == 1
            ? String(localized: "1 tren a l'estació")
            : String(localized: "\(count) trens a l'estació")
    }

    /// Catalan VoiceOver wording of the marker: the line and where the train is
    /// going, plus whether the feed says it is late.
    private func trainAccessibilityLabel(_ train: RodaliesLiveTrain) -> String {
        let destination = train.headsign ?? String(localized: "destí desconegut")
        var label = String(localized: "Tren de la \(train.lineCode) cap a \(destination)")
        let status = RodaliesDepartureText.delay(seconds: train.delaySeconds)
        if status.isDelayed {
            label += ". \(status.text)"
        }
        return label
    }
}
