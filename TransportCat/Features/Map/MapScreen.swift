import MapKit
import SwiftUI

/// Live map of one line: physical route as a polyline overlay, stations and
/// computed train positions as annotations.
struct MapScreen: View {
    @EnvironmentObject private var app: AppModel
    @State private var selectedLineCode = MetroLine.allLines[0].code
    @State private var lineState: LineState?
    @State private var selectedStation: Station?

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
        Map(initialPosition: .region(Self.barcelonaRegion)) {
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
        .task(id: selectedLineCode) {
            let state = LineState(line: selectedLine, client: client)
            self.lineState = state
            await state.run()
        }
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
