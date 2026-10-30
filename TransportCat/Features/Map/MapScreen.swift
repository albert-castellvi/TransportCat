import MapKit
import SwiftUI

/// Live map of one line: physical route as a polyline overlay, stations and
/// computed train positions as annotations.
struct MapScreen: View {
    @EnvironmentObject private var app: AppModel
    @State private var selectedLineCode = MetroLine.allLines[0].code
    @State private var lineState: LineState?
    @State private var selectedStation: Station?
    /// Camera bearing of the visible map region, in degrees clockwise from
    /// north. The train pictograms are rotated against it so they keep facing
    /// along the track whatever the user does with the map (S2).
    @State private var cameraHeading: Double = 0
    /// Latitude span currently on screen, used to decide whether the train
    /// labels are drawn at all (S3).
    @State private var latitudeSpan: Double = MapScreen.barcelonaRegion.span.latitudeDelta
    // Named type instead of `Self` on purpose: a stored-property initializer has
    // no instance context, so the spelled-out type name is the form that is
    // guaranteed to compile.
    @State private var cameraPosition: MapCameraPosition = .region(MapScreen.barcelonaRegion)

    private var selectedLine: MetroLine {
        MetroLine.line(forCode: selectedLineCode) ?? MetroLine.allLines[0]
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                LinePicker(selectedLineCode: $selectedLineCode)
                chipsRow
                mapArea
            }
            .navigationTitle("Mapa")
            .navigationBarTitleDisplayMode(.inline)
            // The loader task must live on the always-visible container: the
            // map itself only renders once LineState exists, so a task attached
            // there would never start (infinite "Carregant…").
            .task(id: selectedLineCode) {
                guard let client = app.client else { return }
                let state = LineState(line: selectedLine, client: client)
                self.lineState = state
                await state.run()
            }
        }
        // The station sheet is presented by the stack itself and declares its
        // detents here instead of inside the presented view: presenting it from
        // a view nested in the stack is what left its first rows under the
        // navigation bar in build 23 (spec S9).
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
    private var mapArea: some View {
        if let message = app.missingCredentialsMessage {
            ConfigurationNotice(message: message)
        } else if let client = app.client, let state = lineState {
            lineMap(state: state, client: client)
        } else {
            ProgressView("Carregant…")
        }
    }

    @ViewBuilder
    private func lineMap(state: LineState, client: TMBClient) -> some View {
        let terminalCodes = Self.terminalStationCodes(in: state.stations)
        Map(position: $cameraPosition) {
            if let geometry = state.geometry {
                MapPolyline(coordinates: geometry.points.map { point in
                    CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
                })
                .stroke(Color(hex: selectedLine.colorHex), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            }
            ForEach(state.stations) { station in
                Annotation(station.name, coordinate: CLLocationCoordinate2D(latitude: station.latitude, longitude: station.longitude)) {
                    Button {
                        selectedStation = station
                    } label: {
                        StationMarker(line: selectedLine, terminal: terminalCodes.contains(station.code))
                    }
                }
            }
            ForEach(state.positions) { position in
                // Empty title: the destination is already on the marker.
                Annotation("", coordinate: CLLocationCoordinate2D(latitude: position.position.latitude, longitude: position.position.longitude)) {
                    TrainMarker(
                        imageName: "train-\(trainLine(for: position).assetKey)",
                        destination: position.destination,
                        rotation: position.heading - 90 - cameraHeading,
                        showLabel: latitudeSpan < Self.labelSpanThreshold
                    )
                }
            }
        }
        .mapStyle(.standard(elevation: .flat))
        .onMapCameraChange(frequency: .onEnd) { context in
            cameraHeading = context.camera.heading
            latitudeSpan = context.region.span.latitudeDelta
        }
        .overlay(alignment: .bottomTrailing) {
            if state.isPolling {
                ProgressView()
                    .padding(12)
                    .background(.thinMaterial, in: Circle())
                    .padding(16)
            }
        }
        .overlay {
            if let error = state.errorMessage {
                Text(error)
                    .font(.footnote)
                    .padding(10)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .padding(16)
            }
        }
        .overlay {
            // Five lines publish no arrivals: an empty map would read as a bug,
            // so the reason goes on top of it (spec S8).
            if state.isFeedEmpty {
                NoRealtimeDataCard()
            }
        }
        .onAppear {
            fitCamera(to: state.stations)
        }
        .onChange(of: state.stations.map(\.code)) { _, _ in
            fitCamera(to: state.stations)
        }
    }

    /// Refit the camera on the stations of the line currently shown, so a long
    /// line such as L5 is not cut off by the fixed Barcelona region (S5).
    /// An empty station list leaves the camera where it is.
    private func fitCamera(to stations: [Station]) {
        guard let region = Self.region(fitting: stations) else { return }
        withAnimation(.easeInOut(duration: 0.35)) {
            cameraPosition = .region(region)
        }
    }

    /// Smallest span kept per axis, so a single station (or a handful sitting
    /// on the same point) does not zoom the map in to street level.
    private static let minSpanDegrees = 0.01

    /// Region that contains every station, padded by 30 % per axis so the end
    /// stations do not touch the edge of the screen. Nil for an empty list.
    static func region(fitting stations: [Station]) -> MKCoordinateRegion? {
        guard let first = stations.first else { return nil }
        var minLatitude = first.latitude
        var maxLatitude = first.latitude
        var minLongitude = first.longitude
        var maxLongitude = first.longitude
        for station in stations {
            minLatitude = min(minLatitude, station.latitude)
            maxLatitude = max(maxLatitude, station.latitude)
            minLongitude = min(minLongitude, station.longitude)
            maxLongitude = max(maxLongitude, station.longitude)
        }
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: (minLatitude + maxLatitude) / 2,
                longitude: (minLongitude + maxLongitude) / 2
            ),
            span: MKCoordinateSpan(
                latitudeDelta: max((maxLatitude - minLatitude) * 1.3, minSpanDegrees),
                longitudeDelta: max((maxLongitude - minLongitude) * 1.3, minSpanDegrees)
            )
        )
    }

    static let barcelonaRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 41.3925, longitude: 2.1649),
        span: MKCoordinateSpan(latitudeDelta: 0.16, longitudeDelta: 0.14)
    )

    /// Below this visible latitude span the destination labels are drawn; above
    /// it they overlapped each other on the busy lines (S3).
    private static let labelSpanThreshold = 0.05

    /// The line a train marker belongs to: the code of the position itself,
    /// falling back to the line on screen when the feed reports an unknown one.
    private func trainLine(for position: TrainPosition) -> MetroLine {
        MetroLine.line(forCode: position.lineCode) ?? selectedLine
    }

    /// Codes of the two end stations of the shown line, which get the terminal
    /// marker instead of the plain one (S4).
    private static func terminalStationCodes(in stations: [Station]) -> Set<Int> {
        guard let first = stations.min(by: { $0.orderInLine < $1.orderInLine }),
              let last = stations.max(by: { $0.orderInLine < $1.orderInLine }) else { return [] }
        return [first.code, last.code]
    }
}

/// Station marker on the map: the pre-rendered dot tinted with the line color
/// (S4), 18 pt for a normal station and 22 pt for a terminal.
private struct StationMarker: View {
    let line: MetroLine
    let terminal: Bool

    var body: some View {
        Image("\(terminal ? "terminal" : "station")-\(line.assetKey)")
            .resizable()
            .frame(width: size, height: size)
    }

    private var size: CGFloat { terminal ? 22 : 18 }
}

/// Moving train marker with its destination label (S1).
private struct TrainMarker: View {
    let imageName: String
    let destination: String
    /// Rotation applied to the pictogram: `heading - 90 - cameraHeading`, the
    /// assets face east and the map may be rotated by the user.
    let rotation: Double
    let showLabel: Bool

    var body: some View {
        // MapKit centers an annotation on its coordinate, so only the image is
        // rotated and `rotationEffect` keeps the layout size at 36x30 pt: the
        // label lives in an overlay on that unrotated frame, which adds nothing
        // to the marker size and always stays upright.
        Image(imageName)
            .resizable()
            .frame(width: 36, height: 30)
            .rotationEffect(.degrees(rotation))
            .overlay(alignment: .bottom) {
                if showLabel {
                    Text(destination)
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.thinMaterial, in: Capsule())
                        .fixedSize()
                        .offset(y: 24)
                }
            }
            .accessibilityLabel("Tren \(destination)")
    }
}
