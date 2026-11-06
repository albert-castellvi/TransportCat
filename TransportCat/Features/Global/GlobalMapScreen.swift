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
@MainActor
struct GlobalMapScreen: View {
    /// Whether the global mode is the one on screen (spec S13). `RootView` keeps
    /// all four map screens mounted (spec S12), so this flag — and not the
    /// view's lifecycle — is what says whether the screen may poll: the global
    /// poller only runs while Tot is visible, and coming back resumes on
    /// `GlobalNetworkState`, which keeps the line states it already built.
    let isActive: Bool
    @EnvironmentObject private var app: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Operator filter chips, persisted as a comma-joined token list (S8).
    @AppStorage(GlobalOperatorSelection.storageKey) private var operatorsRaw = GlobalOperatorSelection.defaultRaw
    /// FGC stations placed on screen, refreshed off the render path exactly
    /// like the FGC map's dots (spec S7).
    @State private var fgcStations: [FGCStation] = []
    /// Map coordinates of every layer's polylines, converted once per layer
    /// change instead of on every 10 Hz redraw (spec S8). Keyed by
    /// `MapLineLayer.id`, which is unique across operators ("metro:1",
    /// "bus:212", "S1").
    @State private var lineCoordinates: [String: [[CLLocationCoordinate2D]]] = [:]
    @State private var selectedIncident: GlobalIncidentStation?
    /// Camera bearing, so the train pictograms keep facing along the track
    /// whatever the rider does with the map (as on every other map here).
    /// Written only when the heading moves a visible amount (one degree,
    /// `GlobalCamera`): below that the counter-rotation is identical, and
    /// skipping the write keeps continuous camera changes from re-diffing
    /// the whole map content.
    @State private var cameraHeading: Double = 0
    /// Visible latitude span at the last band change — the input of the zoom
    /// ladder (S8). Only written when the band actually changes: the camera
    /// callbacks feed `GlobalZoom`'s hysteresis directly, so a span wobbling
    /// inside the margin never rewrites state (and never re-diffs the map).
    /// It starts at the opening span below (spec S9), so the first paint is
    /// already on the band it opens with, before MapKit reports the first
    /// camera change.
    @State private var latitudeSpan: Double = GlobalMapScreen.initialRegion.span.latitudeDelta
    /// The zoom band the map draws right now (spec S8). Stored, not derived
    /// from `latitudeSpan`, so it only changes when `GlobalZoom`'s
    /// hysteresis says the span cleared a threshold by the margin — a 10 Hz
    /// vehicle tick or a sub-threshold camera wobble never invalidates the
    /// map content through it.
    @State private var zoomLevel: GlobalZoomLevel = GlobalZoom.level(
        forLatitudeSpan: GlobalMapScreen.initialRegion.span.latitudeDelta
    )
    // Named type instead of `Self` on purpose: a stored-property initializer
    // has no instance context.
    @State private var cameraPosition: MapCameraPosition = .region(GlobalMapScreen.initialRegion)

    /// Region the map opens with (spec S9): the metro map's Barcelona frame,
    /// pulled back past the `GlobalZoom` station threshold so the launch zoom
    /// is the lines-only band and the station dots stay off the first paint.
    /// The `0.14/0.16` aspect of `barcelonaRegion` is kept for the longitude.
    private static let initialRegion = MKCoordinateRegion(
        center: MapScreen.barcelonaRegion.center,
        span: MKCoordinateSpan(
            latitudeDelta: GlobalZoom.initialLatitudeSpan,
            longitudeDelta: 0.26
        )
    )

    private var state: GlobalNetworkState { GlobalNetworkState.shared }
    private var fgc: FGCNetworkState { FGCNetworkState.shared }

    private var selectedOperators: Set<GlobalOperator> {
        GlobalOperatorSelection.decode(operatorsRaw)
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
            // The one global poller, alive only while this mode is the one on
            // screen (specs S8, S13): the task is keyed on `isActive`, so
            // leaving Tot cancels the poll and its 10 Hz ticker, and coming
            // back resumes on `GlobalNetworkState`, whose line states are
            // already loaded — no topology is fetched twice.
            .task(id: isActive) {
                guard isActive else { return }
                await state.run()
            }
            .onAppear {
                refreshFGCStations()
                refreshLineCoordinates()
                updateFrameContext(level: zoomLevel, latitudeSpan: latitudeSpan)
            }
            .onChange(of: isActive) { _, active in
                guard PerfTelemetry.isEnabled else { return }
                if active {
                    updateFrameContext(level: zoomLevel, latitudeSpan: latitudeSpan)
                } else {
                    FrameMonitor.shared.end(ifMode: "global")
                }
            }
            .onChange(of: scenePhase) { _, phase in
                guard PerfTelemetry.isEnabled else { return }
                if phase != .active { FrameMonitor.shared.end(ifMode: "global") }
            }
            .onDisappear {
                guard PerfTelemetry.isEnabled else { return }
                FrameMonitor.shared.end(ifMode: "global")
            }
            .onChange(of: operatorsRaw) { _, _ in
                updateFrameContext(level: zoomLevel, latitudeSpan: latitudeSpan)
            }
            .onChange(of: fgc.stations.count) { _, _ in refreshFGCStations() }
            // The layers themselves, not their count: the coordinates of every
            // polyline are derived on the change and then read by the render
            // path (spec S8).
            .onChange(of: state.metroLineLayers) { _, _ in refreshLineCoordinates() }
            .onChange(of: state.busLineLayers) { _, _ in refreshLineCoordinates() }
            .onChange(of: fgc.lineLayers) { _, _ in refreshLineCoordinates() }
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
        let evaluationStart = PerfTelemetry.isEnabled ? DispatchTime.now().uptimeNanoseconds : 0
        defer {
            if PerfTelemetry.isEnabled {
                PerfTrace.mapBodyEvaluated(nanoseconds: DispatchTime.now().uptimeNanoseconds - evaluationStart)
            }
        }
        return Map(position: $cameraPosition) {
            linePolylines

            // Stations join from 0.25° down (spec S8 and S9: the launch span
            // is above that threshold, so no dots on the first paint).
            if zoomLevel.includesStations {
                stationDotsContent
            }

            if selectedOperators.contains(.metro) {
                incidentMarkersContent
            }

            // Vehicles with labels join below 0.08° (spec S8).
            if zoomLevel.includesVehicles {
                vehicleAnnotationsContent
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
        // camera, but neither may rewrite state on every callback (spec S8):
        // the band goes through `GlobalZoom`'s hysteresis and is stored only
        // when it really changes, and the heading only when it moves a
        // visible degree — so camera changes cannot invalidate the map by
        // themselves.
        .onMapCameraChange(frequency: .continuous) { context in
            let nextSpan = context.region.span.latitudeDelta
            if PerfTelemetry.isEnabled, isActive { FrameMonitor.shared.cameraChanged(latitudeSpan: nextSpan) }
            let nextLevel = GlobalZoom.level(forLatitudeSpan: nextSpan, previous: zoomLevel)
            if nextLevel != zoomLevel {
                if isActive {
                    recordBandChange(from: zoomLevel, to: nextLevel, latitudeSpan: nextSpan)
                }
                zoomLevel = nextLevel
                latitudeSpan = nextSpan
            }
            if GlobalCamera.isHeadingChangeSignificant(from: cameraHeading, to: context.camera.heading) {
                cameraHeading = context.camera.heading
            }
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

    // MARK: - Map content sections

    /// The map content is split by data source so each section reads only its
    /// own inputs: the lines and the stations below never touch the 10 Hz
    /// vehicle streams, so a vehicle tick re-diffs them without changing a
    /// single value — and every `Equatable` marker view in them skips its
    /// body instead of being rebuilt (spec S8).

    /// Lines: always drawn (spec S8). Depends only on the layer arrays and
    /// the coordinates cached per layer change — never on the vehicle
    /// streams.
    @MapContentBuilder
    private var linePolylines: some MapContent {
        ForEach(shownMetroLayers) { layer in
            polyline(layer: layer, lineWidth: 4)
        }
        ForEach(shownFGCLayers) { layer in
            polyline(layer: layer, lineWidth: 4)
        }
        ForEach(shownBusLayers) { layer in
            polyline(layer: layer, lineWidth: 3)
        }
    }

    /// Station dots, from 0.25° down (spec S8 and S9: the launch span is
    /// above that threshold, so no dots on the first paint). Reads only the
    /// station lists — the dots are stable, `Equatable` value views, so a
    /// vehicle tick's re-diff skips every unchanged dot's body.
    @MapContentBuilder
    private var stationDotsContent: some MapContent {
        ForEach(shownStationDots) { dot in
            Annotation("", coordinate: CLLocationCoordinate2D(latitude: dot.position.latitude, longitude: dot.position.longitude)) {
                StationDot(name: dot.name, colorHex: dot.colorHex)
            }
        }
        ForEach(fgcStationsDots) { station in
            if let point = station.point {
                Annotation("", coordinate: CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)) {
                    StationDot(name: station.name, colorHex: "9E9E9E")
                }
            }
        }
    }

    /// Incident markers are not tied to the station band (spec S9): they are
    /// the one thing the overview zoom must show, so the lines-only first
    /// paint already carries them — and they stay on every closer band
    /// exactly as before. Depends only on the incident list.
    @MapContentBuilder
    private var incidentMarkersContent: some MapContent {
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

    /// Vehicles with labels join below 0.08° (spec S8). The only section that
    /// reads the 10 Hz vehicle streams, and only while the band draws them —
    /// a vehicle republish changes values here and nowhere else in the map
    /// content.
    @MapContentBuilder
    private var vehicleAnnotationsContent: some MapContent {
        ForEach(shownMetroVehicles) { vehicle in
            vehicleAnnotation(vehicle, operator: AppModeCode.metro)
        }
        ForEach(shownFGCVehicles) { vehicle in
            vehicleAnnotation(vehicle, operator: AppModeCode.fgc)
        }
    }

    /// Telemetry only: counts match the annotation branches, not visible
    /// pixels (MapKit may hide overlapping/offscreen annotations).
    private func recordBandChange(from previous: GlobalZoomLevel, to next: GlobalZoomLevel, latitudeSpan: Double) {
        guard PerfTelemetry.isEnabled else { return }
        updateFrameContext(level: next, latitudeSpan: latitudeSpan, bandChanged: true)
        let stationCount = next.includesStations ? shownStationDots.count + fgcStationsDots.count : 0
        let vehicleCount = next.includesVehicles ? shownMetroVehicles.count + shownFGCVehicles.count : 0
        let band: String
        switch next {
        case .lines: band = "lines"
        case .linesAndStations: band = "stations"
        case .linesStationsAndVehicles: band = "vehicles"
        }
        PerfTrace.bandChanged(band: band, stationCount: stationCount, vehicleCount: vehicleCount)
        guard !previous.includesStations, next.includesStations else { return }
        let trace = PerfTrace()
        trace.begin("map.global.stations_appear", tags: [
            "station_count": String(stationCount),
            "latitude_span": String(format: "%.3f", latitudeSpan),
            "fgc_enabled": String(selectedOperators.contains(.fgc))
        ])
        // A frame-observation window, not a measurement of station load time.
        // It can exceed one second if the main actor is stalled.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            trace.end()
        }
    }

    private func updateFrameContext(level: GlobalZoomLevel, latitudeSpan: Double, bandChanged: Bool = false) {
        guard PerfTelemetry.isEnabled else { return }
        let band: String
        switch level {
        case .lines: band = "lines"
        case .linesAndStations: band = "stations"
        case .linesStationsAndVehicles: band = "vehicles"
        }
        FrameMonitor.shared.updateGlobal(tags: [
            "band": band,
            "station_count": String(level.includesStations ? shownStationDots.count + fgcStationsDots.count : 0),
            "vehicle_count": String(level.includesVehicles ? shownMetroVehicles.count + shownFGCVehicles.count : 0),
            "fgc_enabled": String(selectedOperators.contains(.fgc)),
            "latitude_span": String(format: "%.3f", latitudeSpan)
        ], bandChanged: bandChanged)
    }

    /// One line's polylines, stroked in the line color.
    @MapContentBuilder
    private func polyline(layer: MapLineLayer, lineWidth: CGFloat) -> some MapContent {
        ForEach(layer.polylines.indices, id: \.self) { index in
            // Coordinates converted once per layer change (spec S8): the 10 Hz
            // tick must not map every line of the network again.
            let coordinates = polylineCoordinates(of: layer, at: index)
            if coordinates.count >= 2 {
                MapPolyline(coordinates: coordinates)
                    .stroke(
                        Color(hex: layer.colorHex),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
                    )
            }
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
            .accessibilityLabel(vehicleAccessibilityLabel(vehicle, mode: mode))
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
                showName: true,
                opacity: 1
            )
        } else {
            Circle()
                .fill(Color(hex: vehicle.colorHex))
                .frame(width: 12, height: 12)
                .overlay(Circle().stroke(.white, lineWidth: 1.5))
        }
    }

    /// Marker VoiceOver text: "Tren" plus line and destination, and — for FGC
    /// trains whose live feed reports cars (spec S18) — the occupancy summary.
    /// Metro vehicles have no occupancy feed, so their label stays as before.
    private func vehicleAccessibilityLabel(_ vehicle: MapVehicle, mode: String) -> String {
        if let line = MetroLine.line(forCode: vehicle.lineCode) {
            return "Tren \(line.displayName) cap a \(vehicle.label)"
        }
        var label = "Tren \(vehicle.lineCode) cap a \(vehicle.label)"
        if mode == AppModeCode.fgc,
           let train = fgc.trains.first(where: { $0.id == vehicle.id }),
           let occupancy = FGCOccupancy.summary(train) {
            label += ". \(occupancy)"
        }
        return label
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

    /// Converts the polylines of the three layer sources to map coordinates,
    /// once per layer change (spec S8). Called on appear and whenever a layer
    /// set is republished, never from the 10 Hz render path.
    private func refreshLineCoordinates() {
        var coordinates: [String: [[CLLocationCoordinate2D]]] = [:]
        for layer in state.metroLineLayers {
            coordinates[layer.id] = layer.polylines.map { Self.mapCoordinates(of: $0) }
        }
        for layer in state.busLineLayers {
            coordinates[layer.id] = layer.polylines.map { Self.mapCoordinates(of: $0) }
        }
        for layer in fgc.lineLayers {
            coordinates[layer.id] = layer.polylines.map { Self.mapCoordinates(of: $0) }
        }
        lineCoordinates = coordinates
    }

    /// Coordinates of one polyline of a layer, already converted when the layer
    /// was published (spec S8). Empty while the derivation has not run, which
    /// only happens before the layer arrives.
    private func polylineCoordinates(of layer: MapLineLayer, at index: Int) -> [CLLocationCoordinate2D] {
        guard let polylines = lineCoordinates[layer.id], polylines.indices.contains(index) else { return [] }
        return polylines[index]
    }

    /// Map coordinates of a polyline (spec S8): the one place the `GeoPoint` →
    /// `CLLocationCoordinate2D` conversion happens, so it runs when a layer
    /// changes and never on a 10 Hz redraw.
    private static func mapCoordinates(of points: [GeoPoint]) -> [CLLocationCoordinate2D] {
        points.map { point in
            CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
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
/// draw for their stops, in the owning line's color. A small value-type view
/// that is deliberately `Equatable` (with the accessibility label folded in,
/// so the whole annotation label is one comparable value): stations never
/// move, so when a 10 Hz vehicle tick re-diffs the map content, SwiftUI
/// compares the dot values and skips every unchanged dot's body — the
/// vehicle streams can never redraw the 263 station dots.
private struct StationDot: View, Equatable {
    let name: String
    let colorHex: String

    var body: some View {
        Circle()
            .fill(Color(hex: colorHex))
            .frame(width: 10, height: 10)
            .overlay(Circle().stroke(.white, lineWidth: 1.5))
            .accessibilityLabel("Estació \(name)")
    }
}

/// Red warning marker on a station with an active incident (spec S8, S9).
/// `Equatable` like every marker label here, so the incident section re-diffs
/// without rebuilding the markers.
private struct IncidentMarker: View, Equatable {
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
/// `Equatable` so SwiftUI skips the whole marker when neither the art, the
/// destination nor the rotation changed; when only the rotation does (a train
/// gliding along its track), the label below is its own `Equatable` view and
/// skips its body — the `.thinMaterial` capsule is not rebuilt on every
/// 10 Hz tick, which keeps the identical look at a fraction of the cost.
private struct TrainPictogram: View, Equatable {
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
                TrainDestinationLabel(destination: destination)
            }
    }
}

/// Destination capsule under a train pictogram: the text plus its
/// `.thinMaterial` background, exactly as `MapScreen`'s marker draws it.
/// `Equatable` on purpose — the destination rarely changes, so a 10 Hz
/// position tick skips this body entirely and the material capsule is reused
/// instead of being recomputed.
private struct TrainDestinationLabel: View, Equatable {
    let destination: String

    var body: some View {
        Text(destination)
            .font(.caption2.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.thinMaterial, in: Capsule())
            .fixedSize()
            .offset(y: 20)
    }
}
