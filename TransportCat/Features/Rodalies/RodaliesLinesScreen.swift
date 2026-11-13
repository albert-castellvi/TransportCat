import SwiftUI

/// Parades, Rodalies: the stations of the selected line as a timeline in the
/// line colour, one time column per direction (the next departure of the
/// timetable, with Renfe's realtime delay when the feed has it) and the live
/// trains drawn on the rail where the feed places them.
///
/// The header moved to the bottom accessory, as on every mode: this screen keeps
/// only the status capsule.
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

    /// Width of each direction's time column, shared by the header and the rows.
    private static let timeColumnWidth: CGFloat = 64
    /// Refresh period of the time columns: the same 30 s as the feeds.
    private static let refreshIntervalNanoseconds: UInt64 = 30_000_000_000

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
            .networkHeaderBackground(opacity: 0.45)
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

    private func stationsList(line: RodaliesLine) -> some View {
        let trainsByStation = Self.trainsByStation(in: state.trains, lineCode: line.code)
        return ScrollView {
            VStack(spacing: 0) {
                directionHeader
                if stations.isEmpty {
                    Text("Cap estació publicada per a aquesta línia.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(24)
                }
                ForEach(Array(stations.enumerated()), id: \.element.id) { index, station in
                    RodaliesLinesRow(
                        station: station,
                        isFirst: index == 0,
                        isLast: index == stations.count - 1,
                        lineColorHex: line.colorHex,
                        departures: departures[station.id] ?? [:],
                        trains: trainsByStation[station.id] ?? [],
                        timeZone: timeZone,
                        now: now,
                        directionNames: directionNames,
                        onTapStation: { selectedPlace = RodaliesPlaces.place(for: station) },
                        onTapTrain: { train in selectedTrain = train }
                    )
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 16)
        }
    }

    /// The two direction termini above the time columns, so two countdowns are
    /// never ambiguous. A direction the feed does not run keeps an empty column.
    private var directionHeader: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            ForEach(0..<2, id: \.self) { direction in
                Text(directionNames[direction] ?? "")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(width: Self.timeColumnWidth, alignment: .trailing)
                    .accessibilityLabel(
                        directionNames[direction].map { String(localized: "Cap a \($0)") } ?? ""
                    )
            }
        }
        .padding(.trailing, 16)
        .padding(.bottom, 4)
        .accessibilityElement(children: .contain)
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
    /// Codes the timeline does not contain are never read.
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

/// One station row of the Rodalies timeline: the rail in the line colour with
/// its hollow dot, the station name and the two direction time columns, plus the
/// trains the feed places here drawn on the rail.
private struct RodaliesLinesRow: View {
    let station: RodaliesStation
    let isFirst: Bool
    let isLast: Bool
    let lineColorHex: String
    let departures: [Int: RodaliesDeparture]
    let trains: [RodaliesLiveTrain]
    let timeZone: TimeZone
    let now: Date
    let directionNames: [Int: String]
    let onTapStation: () -> Void
    let onTapTrain: (RodaliesLiveTrain) -> Void

    private static let railWidth: CGFloat = 5
    private static let markerColumnLeading: CGFloat = 20
    private static let markerColumnWidth: CGFloat = 18
    private static let markerSize: CGFloat = 16
    private static let rowMinHeight: CGFloat = 56
    private static let timeColumnWidth: CGFloat = 64

    static var spineCenterX: CGFloat { Self.markerColumnLeading + Self.markerColumnWidth / 2 }

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            rail
            Button(action: onTapStation) {
                HStack(spacing: 0) {
                    Text(station.name)
                        .font(.subheadline.weight(.semibold))
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(0..<2, id: \.self) { direction in
                        timeColumn(direction)
                    }
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, 14)
            .padding(.trailing, 16)
            .accessibilityLabel(accessibilityLabel)
        }
        .padding(.vertical, 4)
        .frame(minHeight: Self.rowMinHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay { trainMarkers }
        .accessibilityElement(children: .contain)
    }

    /// The vertical rail with the station's hollow dot; clipped at the dot on
    /// the first and last row so the rail starts and ends with a station.
    private var rail: some View {
        VStack(spacing: 0) {
            segment(visible: !isFirst)
            Circle()
                .fill(Color.white)
                .frame(width: Self.markerSize * 0.6, height: Self.markerSize * 0.6)
                .overlay(Circle().stroke(Color(hex: lineColorHex), lineWidth: 3))
                .frame(width: Self.markerSize, height: Self.markerSize)
            segment(visible: !isLast)
        }
        .frame(width: Self.markerColumnWidth)
        .padding(.leading, Self.markerColumnLeading)
    }

    private func segment(visible: Bool) -> some View {
        Rectangle()
            .fill(visible ? Color(hex: lineColorHex) : Color.clear)
            .frame(width: Self.railWidth)
            .frame(maxHeight: .infinity)
    }

    /// One direction's next departure: "ara" in green, "N min", the wall clock
    /// beyond an hour, or "—" when the direction has nothing ahead.
    @ViewBuilder
    private func timeColumn(_ direction: Int) -> some View {
        let time = departures[direction].map { departure in
            RodaliesDepartureText.time(
                until: departure.expectedAt,
                now: now,
                timeZone: timeZone
            )
        }
        if let time {
            Text(time.text)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(time.isImminent ? Color(hex: "30D158") : Color.primary)
                .lineLimit(1)
                .frame(width: Self.timeColumnWidth, alignment: .trailing)
        } else {
            Text("—")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: Self.timeColumnWidth, alignment: .trailing)
        }
    }

    /// Name plus what the two columns say, read as one element: "Estació
    /// Barcelona-Sants. Cap a Molins de Rei: 5 min."
    private var accessibilityLabel: String {
        var label = String(localized: "Estació \(station.name)")
        for direction in [0, 1] {
            guard let departure = departures[direction] else { continue }
            let time = RodaliesDepartureText.time(
                until: departure.expectedAt,
                now: now,
                timeZone: timeZone
            )
            let destination = directionNames[direction] ?? departure.headsign
            label += ". " + String(localized: "Cap a \(destination): \(time.text)")
        }
        return label
    }

    /// One marker on the rail per train the feed places here, tappable to open
    /// the train sheet. Drawn at the dot's height through the row overlay, so a
    /// row that grows keeps its markers on the dot.
    private var trainMarkers: some View {
        HStack(spacing: -20) {
            ForEach(trains) { train in
                Button {
                    onTapTrain(train)
                } label: {
                    VehicleMarkerView(
                        colorHex: lineColorHex,
                        glyph: .train,
                        headingDegrees: nil,
                        isEstimated: false,
                        isSelected: false,
                        size: 22
                    )
                    // A 22 pt marker is half the 44 pt minimum target, so the
                    // button carries the full frame and the visual marker stays
                    // centred on the rail dot.
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(trainAccessibilityLabel(train))
            }
        }
        .padding(.leading, Self.spineCenterX - 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
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
