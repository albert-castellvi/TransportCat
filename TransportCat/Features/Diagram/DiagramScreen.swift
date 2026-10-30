import SwiftUI

/// Vertical schematic of one line (like andana's interactive diagram):
/// stations as rows on a colored spine, computed trains drawn between rows
/// at their segment progress, and the next arrivals per station inline.
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
                LinePicker(selectedLineCode: $selectedLineCode)
                content
            }
            .navigationTitle("Xarxa")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $selectedStation) { station in
                StationDetailView(station: station, line: selectedLine)
            }
            // Same rule as MapScreen: the loader task lives on the always-
            // visible container, not on the view that requires loaded data.
            .task(id: selectedLineCode) {
                guard let client = app.client else { return }
                let state = LineState(line: selectedLine, client: client)
                self.lineState = state
                await state.run()
            }
        }
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

    private func diagram(state: LineState) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(state.stations.enumerated()), id: \.element.id) { index, station in
                    DiagramRow(
                        station: station,
                        isFirst: index == 0,
                        isLast: index == state.stations.count - 1,
                        colorHex: selectedLine.colorHex,
                        arrivals: state.arrivalsByStop[station.code] ?? []
                    )
                    .onTapGesture { selectedStation = station }
                }
            }
            .padding(.vertical, 16)
            .overlay(alignment: .top) {
                TrainOverlay(state: state, colorHex: selectedLine.colorHex)
                    .allowsHitTesting(false)
            }
        }
        .refreshable {
            await state.pollArrivals()
        }
    }
}

/// One station row of the diagram.
private struct DiagramRow: View {
    let station: Station
    let isFirst: Bool
    let isLast: Bool
    let colorHex: String
    let arrivals: [Arrival]

    static let rowHeight: CGFloat = 56

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                if !isFirst {
                    Rectangle()
                        .fill(Color(hex: colorHex))
                        .frame(width: 5)
                        .offset(y: -Self.rowHeight / 2)
                }
                if !isLast {
                    Rectangle()
                        .fill(Color(hex: colorHex))
                        .frame(width: 5)
                        .offset(y: Self.rowHeight / 2)
                }
                Circle()
                    .fill(Color(hex: colorHex))
                    .frame(width: 16, height: 16)
                    .overlay(Circle().stroke(.white, lineWidth: 2))
            }
            .frame(width: 16, height: Self.rowHeight)

            VStack(alignment: .leading, spacing: 2) {
                Text(station.name)
                    .font(.subheadline.weight(.semibold))
                if let accessible = station.accessible {
                    if accessible {
                        Label("Accessible", image: "icon-accessible")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            if let next = arrivals.compactMap({ $0 }).min(by: { ($0.seconds ?? .max) < ($1.seconds ?? .max) }), let seconds = next.seconds {
                Text(Arrival.countdownText(seconds: seconds))
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
            }
        }
        .frame(height: Self.rowHeight)
        .padding(.horizontal, 16)
        .contentShape(Rectangle())
    }
}

/// Draws computed trains between the station rows of the diagram.
private struct TrainOverlay: View {
    let state: LineState
    let colorHex: String

    var body: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                let rowHeight = DiagramRow.rowHeight
                let indexByCode = Dictionary(
                    grouping: state.stations.enumerated().map { ($1.code, $0) },
                    by: { $0.0 }
                ).compactMapValues { $0.first?.1 }

                for train in state.positions {
                    guard let nextIndex = indexByCode[train.nextStationCode] else { continue }
                    let y: CGFloat
                    if train.forward {
                        y = (CGFloat(nextIndex - 1) + train.segmentProgress) * rowHeight
                    } else {
                        y = (CGFloat(nextIndex + 1) - train.segmentProgress) * rowHeight
                    }
                    guard y >= 0, y <= size.height + rowHeight else { continue }
                    let rect = CGRect(x: proxy.size.width / 2 - 7, y: y - 7, width: 14, height: 14)
                    context.fill(Path(ellipseIn: rect), with: .color(Color(hex: colorHex)))
                    context.stroke(Path(ellipseIn: rect), with: .color(.white), lineWidth: 2)
                }
            }
        }
        .padding(.top, 16)
    }
}
