import MapKit
import SwiftUI

/// Live map of one line: physical route as a polyline overlay, stations and
/// computed train positions as annotations.
struct MapScreen: View {
    @EnvironmentObject private var app: AppModel
    @State private var selectedLineCode = MetroLine.allLines[0].code
    @State private var lineState: LineState?
    @State private var selectedStation: Station?
    // Named type instead of `Self` on purpose: a stored-property initializer has
    // no instance context, so the spelled-out type name is the form that is
    // guaranteed to compile.
    @State private var cameraPosition: MapCameraPosition = .region(MapScreen.barcelonaRegion)

    private var selectedLine: MetroLine {
        MetroLine.line(forCode: selectedLineCode) ?? MetroLine.allLines[0]
    }

    private var lineAlerts: [ServiceAlert] {
        app.alerts(affecting: selectedLineCode)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                LinePicker(selectedLineCode: $selectedLineCode)
                if !lineAlerts.isEmpty {
                    AlertBanner(alerts: lineAlerts, lineColor: selectedLine.colorHex)
                }
                mapArea
            }
            .navigationTitle("Mapa")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $selectedStation) { station in
                StationDetailView(station: station, line: selectedLine)
            }
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
                        StationDot(color: selectedLine.colorHex)
                    }
                }
            }
            ForEach(state.positions) { position in
                Annotation("Tren \(position.destination)", coordinate: CLLocationCoordinate2D(latitude: position.position.latitude, longitude: position.position.longitude)) {
                    TrainDot(color: selectedLine.colorHex, destination: position.destination)
                }
            }
        }
        .mapStyle(.standard(elevation: .flat))
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
}

/// Small colored station dot used on the map.
struct StationDot: View {
    let color: String

    var body: some View {
        Circle()
            .fill(Color(hex: color))
            .frame(width: 12, height: 12)
            .overlay(Circle().stroke(.white, lineWidth: 2))
            .shadow(radius: 1)
    }
}

/// Moving train marker with its destination label.
struct TrainDot: View {
    let color: String
    let destination: String

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Color(hex: color))
                .frame(width: 16, height: 16)
                .overlay(Circle().stroke(.white, lineWidth: 2))
                .shadow(radius: 2)
            Text(destination)
                .font(.caption2.bold())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.thinMaterial, in: Capsule())
        }
    }
}
