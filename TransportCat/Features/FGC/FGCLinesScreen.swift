import SwiftUI

/// Parades, FGC (spec S10, D1): the stations of the selected line on a rail in
/// the line colour, with the trains ON the rail and their destination — no
/// minute columns, because the FGC open feed publishes no ETAs. Tapping a
/// train opens the same train sheet the map shows, without the follow button:
/// there is no camera to move here.
///
/// The header moved to the bottom accessory (T1): this screen keeps only the
/// status capsule (`FreshnessChip`, styled there).
struct FGCLinesScreen: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("fgcSelectedLine") private var selectedLineCode = FGCLinePicker.defaultLineCode
    /// Stations of the line on screen, refreshed off the render path, exactly
    /// like the map's dots (spec S7, S10).
    @State private var shownStations: [FGCStation] = []
    /// Train whose sheet is open. Snapshot copy; the sheet reads the live
    /// values from the shared state by id.
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
                statusCapsule
                content
            }
            // The bottom accessory (T1) carries the mode menu and the line
            // chip; the screen keeps no title bar of its own (spec S5).
            // The icon's network behind the top, fading out (spec S11).
            .networkHeaderBackground(opacity: 0.45)
            .navigationBarHidden(true)
            .sensoryFeedback(.selection, trigger: selectedLineCode)
            .onAppear { refreshStations() }
            .onChange(of: selectedLineCode) { _, _ in refreshStations() }
            .onChange(of: state.lineLayers.count) { _, _ in refreshStations() }
        }
        // Same sheet as the map, presented by the stack itself. No follow
        // button: this screen has no camera.
        .sheet(item: $selectedTrain) { train in
            FGCTrainSheet(
                trainID: train.id,
                followingVehicleID: .constant(nil)
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    /// The status capsule, top-left (spec S2): the existing `FreshnessChip`
    /// explicit-values initializer, restyled by T1 — this screen only calls it.
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
    /// (spec S10). Trains are indexed once per render, not searched per row.
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
                        trains: plan[station.code] ?? [],
                        onTapTrain: { train in selectedTrain = train }
                    )
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 16)
        }
    }

    private func refreshStations() {
        shownStations = FGCLineStations.stations(for: shownLayer, in: state.stations)
    }

    /// Live trains of one line, keyed by the station code they show at (S10):
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

/// One train on one station row, with the wording the marker card shows
/// (spec S10, D1: no minutes — the destination is all the feed gives).
fileprivate struct FGCDisplayedTrain: Identifiable {
    let train: FGCTrain
    /// Destination name, falling back to the raw `desti` code.
    let destination: String
    /// True when `estacionat_a` is this station, false when the station is
    /// merely the first announced stop.
    let stopped: Bool

    var id: String { train.id }

    /// Catalan VoiceOver wording of the marker: the run state and the
    /// destination, plus the occupancy summary when FGC publishes one
    /// (spec S18, preserved).
    var accessibilityLabel: String {
        let base = stopped
            ? "Tren \(train.lineCode) aturat, cap a \(destination)"
            : "Tren \(train.lineCode) en marxa, cap a \(destination)"
        guard let occupancy = FGCOccupancy.summary(train) else { return base }
        return "\(base). \(occupancy)"
    }
}

/// One station row of the FGC timeline (spec S10): the rail in the line
/// colour with its hollow dot, the station name, and the trains at it drawn
/// ON the rail with the S6 marker plus their destination as a small label.
private struct FGCLinesRow: View {
    let station: FGCStation
    let isFirst: Bool
    let isLast: Bool
    let lineColorHex: String
    let trains: [FGCDisplayedTrain]
    let onTapTrain: (FGCTrain) -> Void

    /// Width of the marker column and of the rail, as on the other timelines.
    private static let railWidth: CGFloat = 5
    private static let markerColumnLeading: CGFloat = 20
    private static let markerColumnWidth: CGFloat = 18
    private static let markerSize: CGFloat = 16
    private static let rowMinHeight: CGFloat = 56

    static var spineCenterX: CGFloat { Self.markerColumnLeading + Self.markerColumnWidth / 2 }

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            rail
            VStack(alignment: .leading, spacing: 4) {
                Text(station.name)
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.leading)
                    .accessibilityLabel("Estació \(station.name)")
                if !trains.isEmpty {
                    trainLabels
                }
            }
            .padding(.leading, 14)
            Spacer(minLength: 16)
        }
        .padding(.vertical, 4)
        .frame(minHeight: Self.rowMinHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The overlay is the whole row, whatever height the content needed: a
        // row that grows past `rowMinHeight` (a wrapped name, several trains, a
        // larger Dynamic Type) keeps the markers on the rail dot.
        .overlay { trainMarkers }
        .accessibilityElement(children: .contain)
    }
    /// The vertical rail with the station's hollow dot on it. The rail is
    /// clipped at the dot on the first and last row so it starts and ends
    /// with a station, as on the other timelines.
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

    /// The half of the rail above or below the dot.
    private func segment(visible: Bool) -> some View {
        Rectangle()
            .fill(visible ? Color(hex: lineColorHex) : Color.clear)
            .frame(width: Self.railWidth)
            .frame(maxHeight: .infinity)
    }

    /// The destinations of the trains at this station, next to the name
    /// (D1: no minute columns). The markers themselves are drawn on the rail.
    private var trainLabels: some View {
        HStack(spacing: 6) {
            ForEach(trains) { displayed in
                Button {
                    onTapTrain(displayed.train)
                } label: {
                    Text(displayed.destination)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                // The marker on the rail is this train's control, so the
                // label button stays out of the accessibility tree instead of
                // announcing the same train twice (#83).
                .accessibilityHidden(true)
            }
        }
    }

    /// One S6 vehicle marker on the rail per train at this station, tappable
    /// to open the train sheet. Drawn at the dot's height: the overlay's
    /// frame is the whole row, so the vertical position is the row's center
    /// measured from the top, where the rail dot sits — never a fixed band
    /// anchored at the row's top, which drifts once the row grows.
    private var trainMarkers: some View {
        HStack(spacing: -20) {
            ForEach(trains) { displayed in
                Button {
                    onTapTrain(displayed.train)
                } label: {
                    VehicleMarkerView(
                        colorHex: lineColorHex,
                        glyph: .train,
                        headingDegrees: nil,
                        isEstimated: false,
                        isSelected: false,
                        size: 22
                    )
                    // A 22 pt marker is half the 44 pt minimum target, so
                    // the button carries the full frame and the visual
                    // marker stays centered on the rail dot (#83). The
                    // negative spacing keeps consecutive markers at the same
                    // visual distance a 22 pt marker row had.
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(displayed.accessibilityLabel)
            }
        }
        .padding(.leading, Self.spineCenterX - 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}
