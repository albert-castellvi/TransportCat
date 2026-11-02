import SwiftUI

/// The Línies tab of the FGC mode (spec S9): the stations of the selected
/// line on a vertical spine in the line color, each with the trains that are
/// stopped at it or whose first announced stop it is. Tapping a train badge
/// opens the same train sheet the map shows, without the follow button: there
/// is no camera to move here.
///
/// The header is the map's header — mode selector, line chips, freshness chip
/// — and the chips write the same `fgcSelectedLine` key, so the two screens
/// always speak about the same line.
struct FGCLinesScreen: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("fgcSelectedLine") private var selectedLineCode = FGCLinePicker.defaultLineCode
    /// Stations of the line on screen, refreshed off the render path, exactly
    /// like the map's dots (spec S7, S9).
    @State private var shownStations: [FGCStation] = []
    /// Train whose sheet is open (spec S9). Snapshot copy; the sheet reads the
    /// live values from the shared state by id.
    @State private var selectedTrain: FGCTrain?

    init() {}

    private var state: FGCNetworkState { FGCNetworkState.shared }

    private var shownLineCode: String {
        FGCLinePicker.resolve(selected: selectedLineCode, from: state.lineLayers)
    }

    private var shownLayer: MapLineLayer? {
        state.lineLayers.first { $0.code == shownLineCode }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                content
            }
            .sensoryFeedback(.selection, trigger: selectedLineCode)
            .navigationTitle("Línies")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { refreshStations() }
            .onChange(of: selectedLineCode) { _, _ in refreshStations() }
            .onChange(of: state.lineLayers.count) { _, _ in refreshStations() }
        }
        // Same sheet as the map (spec S8), presented by the stack itself. No
        // follow button: this screen has no camera (spec S9).
        .sheet(item: $selectedTrain) { train in
            FGCTrainSheet(
                trainID: train.id,
                followingVehicleID: .constant(nil)
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 0) {
            ModeSelector()
                .padding(.horizontal, 16)
                .padding(.top, 8)
            FGCLinePicker(layers: state.lineLayers, selectedLineCode: $selectedLineCode)
            chipsRow
        }
    }

    /// Freshness of the 30 s FGC poll, arriving with its first answer, exactly
    /// as on the map (spec S9, S10).
    @ViewBuilder
    private var chipsRow: some View {
        HStack(spacing: 8) {
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
        .padding(.leading, 16)
        .padding(.bottom, 8)
        .animation(AppMotion.smooth(reduceMotion: reduceMotion), value: hasLiveSignal)
    }

    /// Whether the live feed has said anything yet: a successful poll or a
    /// failed one. Before that the chip would only read "Sense dades".
    private var hasLiveSignal: Bool {
        state.arrivalsUpdatedAt != nil || state.lastPollFailed
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let layer = shownLayer {
            stationsList(layer: layer)
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

    /// Stations in `codigo-estaciones.ordre` order with the trains at each one
    /// (spec S9). Trains are indexed once per render, not searched per row.
    private func stationsList(layer: MapLineLayer) -> some View {
        let plan = Self.trainsByStation(in: state.trains, lineCode: layer.code)
        return ScrollView {
            VStack(spacing: 0) {
                if shownStations.isEmpty {
                    // A line whose stations the catalog does not place; the
                    // list says so instead of spinning forever.
                    Text("Cap estació publicada per a aquesta línia.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(24)
                }
                ForEach(Array(shownStations.enumerated()), id: \.element.id) { index, station in
                    FGCLinesRow(
                        station: station,
                        isFirst: index == 0,
                        isLast: index == shownStations.count - 1,
                        lineColorHex: layer.colorHex,
                        lineTextColorHex: layer.textColorHex,
                        trains: plan[station.code] ?? [],
                        onTapTrain: { train in selectedTrain = train }
                    )
                }
            }
            .padding(.top, 16)
            .padding(.bottom, 16)
        }
    }

    private func refreshStations() {
        shownStations = FGCLineStations.stations(for: shownLayer, in: state.stations)
    }

    /// Live trains of one line, keyed by the station code they show at (S9):
    /// every train whose resolved base line is the line on screen, keyed to
    /// its stop when it is `estacionat_a` there, else to its first announced
    /// stop. Codes the station list does not contain are simply never read.
    private static func trainsByStation(
        in trains: [FGCTrain],
        lineCode: String
    ) -> [String: [FGCDisplayedTrain]] {
        var result: [String: [FGCDisplayedTrain]] = [:]
        for train in trains where FGCNetwork.baseLineCode(for: train.lineCode) == lineCode {
            let destination = train.destinationName ?? train.destinationCode
            if let code = train.stoppedAtStopCode {
                result[code, default: []].append(
                    FGCDisplayedTrain(train: train, destination: destination, stopped: true)
                )
            } else if let code = train.nextStopCodes.first {
                result[code, default: []].append(
                    FGCDisplayedTrain(train: train, destination: destination, stopped: false)
                )
            }
        }
        return result
    }
}

/// One train on one station row, with the wording the badge shows (spec S9).
fileprivate struct FGCDisplayedTrain: Identifiable {
    let train: FGCTrain
    /// Destination name, falling back to the raw `desti` code.
    let destination: String
    /// True when `estacionat_a` is this station, false when the station is
    /// merely the first announced stop.
    let stopped: Bool

    var id: String { train.id }

    /// Badge text: "→ <destí>" approaching, "<destí>" stopped.
    var label: String { stopped ? destination : "→ \(destination)" }

    /// Catalan VoiceOver wording of the badge: the run state, the destination
    /// and the occupancy summary when FGC publishes one (spec S18).
    var accessibilityLabel: String {
        let base = stopped
            ? "Tren \(train.lineCode) aturat, cap a \(destination)"
            : "Tren \(train.lineCode) en marxa, cap a \(destination)"
        guard let occupancy = FGCOccupancy.summary(train) else { return base }
        return "\(base). \(occupancy)"
    }
}

/// One station row of the FGC lines list (spec S9): the spine segment in the
/// line color with its dot, the station name and the trains at it.
private struct FGCLinesRow: View {
    let station: FGCStation
    let isFirst: Bool
    let isLast: Bool
    let lineColorHex: String
    let lineTextColorHex: String
    let trains: [FGCDisplayedTrain]
    let onTapTrain: (FGCTrain) -> Void

    /// Width of the marker column and of the spine, as on the bus diagram.
    private static let spineWidth: CGFloat = 4
    private static let markerSize: CGFloat = 12
    private static let rowMinHeight: CGFloat = 52

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            spine
            VStack(alignment: .leading, spacing: 4) {
                Text(station.name)
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.leading)
                    .accessibilityLabel("Estació \(station.name)")
                if !trains.isEmpty {
                    badgesRow
                }
            }
            Spacer(minLength: 16)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: Self.rowMinHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    /// The vertical segment with the station's dot on it. The segment is
    /// clipped at the dot on the first and last row so the spine starts and
    /// ends with the station, as in the diagrams of the other modes.
    private var spine: some View {
        VStack(spacing: 0) {
            segment(visible: !isFirst)
            Circle()
                .fill(Color(hex: lineColorHex))
                .frame(width: Self.markerSize, height: Self.markerSize)
                .overlay(Circle().stroke(.white, lineWidth: 1.5))
            segment(visible: !isLast)
        }
    }

    /// The half of the spine above or below the dot.
    private func segment(visible: Bool) -> some View {
        Rectangle()
            .fill(visible ? Color(hex: lineColorHex) : Color.clear)
            .frame(width: Self.spineWidth)
            .frame(maxHeight: .infinity)
    }

    /// One small badge per train, filled with the line colors, tappable to
    /// open the train sheet (spec S9).
    private var badgesRow: some View {
        HStack(spacing: 6) {
            ForEach(trains) { displayed in
                Button {
                    onTapTrain(displayed.train)
                } label: {
                    Text(displayed.label)
                        .font(.caption2.bold())
                        .foregroundStyle(Color(hex: lineTextColorHex))
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            Capsule().fill(
                                Color(hex: lineColorHex)
                                    .opacity(displayed.stopped ? 1 : 0.75)
                            )
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(displayed.accessibilityLabel)
            }
        }
    }
}
