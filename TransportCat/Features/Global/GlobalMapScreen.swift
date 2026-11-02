import MapKit
import SwiftUI

/// The global map (spec S8): every metro line in its color, every FGC line,
/// the route polylines of the favorite bus lines and the live trains of both
/// rail networks, on one map.
///
/// The drawing rule is the zoom ladder of `GlobalZoom`: above 0.25° only the
/// lines, down to 0.08° station dots are added, closer still the vehicles
/// with their labels. Metro data comes from the single `GlobalNetworkState`
/// poller started by this screen's `.task`; FGC trains ride on the shared
/// `FGCNetworkState` poller that `RootView` runs for this mode too. Bus
/// vehicles are never drawn, to protect the TMB quota (spec S8).
///
/// A vehicle tap hands the rider to the operator's own map with its follow
/// sheet through `AppRouter.open(.vehicle(...))` (S10); an incident marker
/// opens the shared `IncidentSheet` (S7).
struct GlobalMapScreen: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Operator filter chips, persisted as a comma-joined token list (S8).
    @AppStorage(GlobalOperatorSelection.storageKey) private var operatorsRaw = GlobalOperatorSelection.defaultRaw
    /// FGC stations placed on screen, refreshed off the render path exactly
    /// like the FGC map's dots (spec S7).
    @State private var fgcStations: [FGCStation] = []
    @State private var selectedIncident: GlobalIncidentStation?
    /// Camera bearing, so the train pictograms keep facing along the track
    /// whatever the rider does with the map (as on every other map here).
    @State private var cameraHeading: Double = 0
    /// Visible latitude span — the input of the zoom ladder (S8).
    @State private var latitudeSpan: Double = MapScreen.barcelonaRegion.span.latitudeDelta
    // Named type instead of `Self` on purpose: a stored-property initializer
    // has no instance context.
    @State private var cameraPosition: MapCameraPosition = .region(MapScreen.barcelonaRegion)

    init() {}

    private var state: GlobalNetworkState { GlobalNetworkState.shared }
    private var fgc: FGCNetworkState { FGCNetworkState.shared }

    private var selectedOperators: Set<GlobalOperator> {
        GlobalOperatorSelection.decode(operatorsRaw)
    }

    private var level: GlobalZoomLevel {
        GlobalZoom.level(forLatitudeSpan: latitudeSpan)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                mapArea
                    .animation(AppMotion.smooth(reduceMotion: reduceMotion), value: hasLayers)
            }
            // Toggling an operator is a selection, so it clicks (polish pass).
            .sensoryFeedback(.selection, trigger: operatorsRaw)
            .navigationTitle("Mapa")
            .navigationBarTitleDisplayMode(.inline)
            // The one global poller, alive only while this screen is visible
            // (spec S8): the task cancels on disappear, and re-entering the
            // mode resumes on the state that is already loaded.
            .task {
                await state.run()
            }
            .onAppear { refreshFGCStations() }
            .onChange(of: fgc.stations.count) { _, _ in refreshFGCStations() }
            // The alerts poll runs app-wide; every new feed refreshes the
            // station incidents without waiting for the next metro pass.
            .onChange(of: app.alertsUpdatedAt) { _, _ in state.refreshIncidents() }
        }
        .sheet(item: $selectedIncident) { incident in
            IncidentSheet(alerts: incident.alerts, title: "Incidències · \(incident.name)")
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
            operatorChips
            chipsRow
        }
    }

    /// Metro / Bus / FGC toggle chips (spec S8), in the `ModeSelector` capsule
    /// style: selected chips are white with black text, hidden operators are
    /// dimmed so the rider always sees all three filters.
    private var operatorChips: some View {
        HStack(spacing: 8) {
            ForEach(GlobalOperator.allCases, id: \.self) { operatorKind in
                let isSelected = selectedOperators.contains(operatorKind)
                Button {
                    var selection = selectedOperators
                    if isSelected {
                        selection.remove(operatorKind)
                    } else {
                        selection.insert(operatorKind)
                    }
                    withAnimation(AppMotion.smooth(duration: 0.2, reduceMotion: reduceMotion)) {
                        operatorsRaw = GlobalOperatorSelection.encode(selection)
                    }
                } label: {
                    Text(operatorKind.label)
                        .font(.system(size: 13, weight: isSelected ? .bold : .semibold))
                        .foregroundStyle(isSelected ? Color.black : Color.white)
                        .padding(.horizontal, 14)
                        .frame(height: 30)
                        .background(Capsule().fill(isSelected ? Color.white : Color(white: 0.17)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(operatorKind.label)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    /// Freshness of the 30 s metro pass (FGC keeps its own chip on its own
    /// screen). Arrives with the first answer, like every other map here.
    @ViewBuilder
    private var chipsRow: some View {
        HStack(spacing: 8) {
            if state.updatedAt != nil || state.lastPollFailed {
                FreshnessChip(
                    updatedAt: state.updatedAt,
                    lastAttemptFailed: state.lastPollFailed,
                    feedEmpty: false
                )
                .transition(AppMotion.chipTransition)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    // MARK: - Map

    /// Whether anything at all is drawable yet.
    private var hasLayers: Bool {
        !state.metroLineLayers.isEmpty || !shownFGCLayers.isEmpty || !state.busLineLayers.isEmpty
    }

    @ViewBuilder
    private var mapArea: some View {
        if let message = app.missingCredentialsMessage {
            ConfigurationNotice(message: message)
        } else if hasLayers {
            networkMap
                .transition(.opacity)
        } else {
            MapLoadingPlaceholder()
                .transition(.opacity)
        }
    }

    private var networkMap: some View {
        Map(position: $cameraPosition) {
            // Lines: always drawn (spec S8).
            ForEach(shownMetroLayers) { layer in
                polyline(layer: layer, lineWidth: 4)
            }
            ForEach(shownFGCLayers) { layer in
                polyline(layer: layer, lineWidth: 4)
            }
            ForEach(shownBusLayers) { layer in
                polyline(layer: layer, lineWidth: 3)
            }

            // Stations and incidents join from 0.25° down (spec S8).
            if level.includesStations {
                ForEach(shownStationDots) { dot in
                    Annotation("", coordinate: CLLocationCoordinate2D(latitude: dot.position.latitude, longitude: dot.position.longitude)) {
                        StationDot(colorHex: dot.colorHex)
                            .accessibilityLabel("Estació \(dot.name)")
                    }
                }
                ForEach(fgcStationsDots) { station in
                    if let point = station.point {
                        Annotation("", coordinate: CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)) {
                            StationDot(colorHex: "9E9E9E")
                                .accessibilityLabel("Estació \(station.name)")
                        }
                    }
                }
                if selectedOperators.contains(.metro) {
                    ForEach(state.incidentStations) { incident in
                        Annotation("", coordinate: CLLocationCoordinate2D(latitude: incident.position.latitude, longitude: incident.position.longitude)) {
                            Button {
                                selectedIncident = incident
                            } label: {
                                IncidentMarker()
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Incidència a \(incident.name)")
                        }
                    }
                }
            }

            // Vehicles with labels join below 0.08° (spec S8).
            if level.includesVehicles {
                ForEach(shownMetroVehicles) { vehicle in
                    vehicleAnnotation(vehicle, operator: AppModeCode.metro)
                }
                ForEach(shownFGCVehicles) { vehicle in
                    vehicleAnnotation(vehicle, operator: AppModeCode.fgc)
                }
            }

            if showsUserLocation {
                UserAnnotation()
            }
        }
        .mapStyle(.standard(elevation: .flat))
        .mapControls {
            if showsUserLocation {
                MapUserLocationButton()
            }
        }
        // The zoom ladder and the marker counter-rotation both need the live
        // camera, so the span and heading update continuously (spec S8).
        .onMapCameraChange(frequency: .continuous) { context in
            cameraHeading = context.camera.heading
            latitudeSpan = context.region.span.latitudeDelta
        }
        // Attribution of the feeds drawn here (spec S10 wording).
        .overlay(alignment: .bottomLeading) {
            Text("Dades: TMB · FGC (CC BY 4.0)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.thinMaterial, in: Capsule())
                .padding(12)
                .allowsHitTesting(false)
        }
        .animation(AppMotion.smooth(duration: 0.35, reduceMotion: reduceMotion), value: state.metroLineLayers.count)
    }

    /// One line's polylines, stroked in the line color.
    private func polyline(layer: MapLineLayer, lineWidth: CGFloat) -> some MapContent {
        ForEach(layer.polylines.indices, id: \.self) { index in
            MapPolyline(coordinates: layer.polylines[index].map { point in
                CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
            })
            .stroke(
                Color(hex: layer.colorHex),
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
            )
        }
    }

    /// One live train: tappable, and the tap hands the rider to the
    /// operator's map with the vehicle focus (spec S8, S10).
    private func vehicleAnnotation(_ vehicle: MapVehicle, operator mode: String) -> some MapContent {
        Annotation("", coordinate: CLLocationCoordinate2D(latitude: vehicle.position.latitude, longitude: vehicle.position.longitude)) {
            Button {
                AppRouter.shared.open(.vehicle(
                    operator: mode,
                    lineCode: vehicle.lineCode,
                    vehicleID: vehicle.id
                ))
            } label: {
                vehicleMarker(vehicle)
            }
            .buttonStyle(.plain)
            // The reused pictogram markers say "Bus"; a train has to say
            // "Tren" to VoiceOver, as on the FGC map (spec S8).
            .accessibilityLabel(vehicleAccessibilityLabel(vehicle))
        }
    }

    /// Metro trains use the pre-rendered line pictograms, FGC trains reuse the
    /// bus marker exactly like the FGC map does, so the two rail networks
    /// never paint the same vehicle differently from their own screens.
    @ViewBuilder
    private func vehicleMarker(_ vehicle: MapVehicle) -> some View {
        let rotation = vehicle.heading - 90 - cameraHeading
        if let line = MetroLine.line(forCode: vehicle.lineCode) {
            TrainPictogram(
                imageName: "train-\(line.assetKey)",
                destination: vehicle.label,
                rotation: rotation
            )
        } else if let layer = shownFGCLayers.first(where: { $0.code == vehicle.lineCode }) {
            BusMarker(
                line: Self.busLine(for: layer),
                destination: vehicle.label,
                rotation: rotation,
                showLabel: true,
                opacity: 1
            )
        } else {
            Circle()
                .fill(Color(hex: vehicle.colorHex))
                .frame(width: 12, height: 12)
                .overlay(Circle().stroke(.white, lineWidth: 1.5))
        }
    }

    private func vehicleAccessibilityLabel(_ vehicle: MapVehicle) -> String {
        if let line = MetroLine.line(forCode: vehicle.lineCode) {
            return "Tren \(line.displayName) cap a \(vehicle.label)"
        }
        return "Tren \(vehicle.lineCode) cap a \(vehicle.label)"
    }

    // MARK: - Visibility filters

    private var shownMetroLayers: [MapLineLayer] {
        selectedOperators.contains(.metro) ? state.metroLineLayers : []
    }

    /// Every drawable FGC line, the same filter the FGC picker applies
    /// (shuttle road routes and polyline-less lines never join the map).
    private var shownFGCLayers: [MapLineLayer] {
        guard selectedOperators.contains(.fgc) else { return [] }
        return FGCLinePicker.selectableLayers(from: fgc.lineLayers)
    }

    private var shownBusLayers: [MapLineLayer] {
        selectedOperators.contains(.bus) ? state.busLineLayers : []
    }

    private var shownStationDots: [GlobalStationDot] {
        selectedOperators.contains(.metro) ? state.stationDots : []
    }

    /// FGC station dots for the map, hidden with the FGC chip. The stored
    /// `fgcStations` list itself is never gated, so flipping the chip back on
    /// needs no reload.
    private var fgcStationsDots: [FGCStation] {
        selectedOperators.contains(.fgc) ? fgcStations : []
    }

    private var shownMetroVehicles: [MapVehicle] {
        selectedOperators.contains(.metro) ? state.vehicles : []
    }

    private var shownFGCVehicles: [MapVehicle] {
        selectedOperators.contains(.fgc) ? fgc.vehicles : []
    }

    /// The FGC station list with coordinates, deduped by code: refreshed off
    /// the render path like the FGC map's dots, never per 10 Hz redraw. The
    /// operator chip hides the result at draw time, so this stays the full
    /// list whatever the chips say.
    private func refreshFGCStations() {
        var seen: Set<String> = []
        fgcStations = fgc.stations.filter { station in
            station.point != nil && seen.insert(station.code).inserted
        }
    }

    // MARK: - Location

    /// `UserAnnotation` and the location button only once the rider granted
    /// when-in-use (spec S11); a denial never blocks the map.
    private var showsUserLocation: Bool {
        let authorization = LocationService.shared.authorization
        return authorization == .authorizedWhenInUse || authorization == .authorizedAlways
    }

    /// `BusMarker` draws from a `BusLine`; the global map reuses that view for
    /// FGC trains with the layer's own colors, exactly as the FGC map does.
    /// Only the fields the marker reads are filled.
    private static func busLine(for layer: MapLineLayer) -> BusLine {
        BusLine(
            code: 0,
            name: layer.code,
            description: layer.code,
            origin: "",
            destination: "",
            colorHex: layer.colorHex,
            textColorHex: layer.textColorHex,
            familyCode: 0,
            familyName: "FGC",
            familyOrder: 0,
            order: 0
        )
    }
}

/// Station dot on the global map: the same 10 pt ring the FGC and bus maps
/// draw for their stops, in the owning line's color.
private struct StationDot: View {
    let colorHex: String

    var body: some View {
        Circle()
            .fill(Color(hex: colorHex))
            .frame(width: 10, height: 10)
            .overlay(Circle().stroke(.white, lineWidth: 1.5))
    }
}

/// Red warning marker on a station with an active incident (spec S8, S9).
private struct IncidentMarker: View {
    var body: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(.red)
            .padding(5)
            .background(.thinMaterial, in: Circle())
    }
}

/// Metro train pictogram for the global map, drawn like the metro map's own
/// marker (the 72:32 art at 42 pt) with its destination label below it.
private struct TrainPictogram: View {
    let imageName: String
    let destination: String
    let rotation: Double

    var body: some View {
        // MapKit centers an annotation on its coordinate, so only the image
        // rotates and the label stays upright in an overlay on the unrotated
        // frame — the same geometry `MapScreen`'s marker uses.
        Image(imageName)
            .resizable()
            .frame(width: 42, height: 18.67)
            .rotationEffect(.degrees(rotation))
            .overlay(alignment: .bottom) {
                Text(destination)
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.thinMaterial, in: Capsule())
                    .fixedSize()
                    .offset(y: 20)
            }
    }
}
