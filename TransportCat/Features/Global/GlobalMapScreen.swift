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
/// A vehicle tap opens the glass card above the accessory in place (spec
/// S6): the destination, the next stop with its countdown when the feed
/// carries one, and whether the position is live or estimated. An incident
/// badge opens its own card with the grouped alerts and a jump to Avisos
/// (spec S7, D6).
@MainActor
struct GlobalMapScreen: View {
    /// Whether the global mode is the one on screen (spec S13). `RootView` keeps
    /// all four map screens mounted (spec S12), so this flag — and not the
    /// view's lifecycle — is what says whether the screen may poll: the global
    /// poller only runs while Tot is visible, and coming back resumes on
    /// `GlobalNetworkState`, which keeps the line states it already built.
    let isActive: Bool
    /// Hook for the nearby sheet (spec S13, T5): called after the location
    /// button centers the camera on the rider. Defaults to nothing.
    var onLocate: (() -> Void)? = nil
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
    /// The vehicle whose glass card is open (spec S6), together with the
    /// operator section the tap came from, which decides the card rows.
    @State private var selectedVehicle: GlobalSelectedVehicle?
    /// The incident badge whose glass card is open (spec S7, D6).
    @State private var selectedBadge: GlobalIncidentBadge?
    /// The station whose sheet is open, set by a tap on its dot (#101).
    @State private var selectedPlace: Place?
    /// Grouped incident badges (spec S7, D6), derived off the 10 Hz render
    /// path: refreshed only when the incidents, the alerts or the metro
    /// topology change, never per vehicle tick.
    @State private var incidentBadges: [GlobalIncidentBadge] = []
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
            ZStack {
                mapArea
                    .animation(AppMotion.smooth(reduceMotion: reduceMotion), value: hasLayers)
            }
            // Spec S1: no header — the mode selector and the operator chips
            // move to the bottom accessory, the map fills the screen under
            // the status bar, and the v2 chrome lives in overlays.
            .overlay(alignment: .topLeading) {
                statusCapsule
                    .padding(.leading, 16)
                    .padding(.top, 8)
            }
            .overlay(alignment: .topTrailing) {
                locationButton
                    .padding(.trailing, 16)
                    .padding(.top, 8)
            }
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
                refreshIncidentBadges()
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
            .onChange(of: state.metroLineLayers) { _, _ in
                refreshLineCoordinates()
                // The line states behind a fresh topology also carry the
                // station order the badge placement reads (spec S7, D6).
                refreshIncidentBadges()
            }
            .onChange(of: state.busLineLayers) { _, _ in refreshLineCoordinates() }
            .onChange(of: fgc.lineLayers) { _, _ in refreshLineCoordinates() }
            // The alerts poll runs app-wide; every new feed refreshes the
            // station incidents without waiting for the next metro pass.
            .onChange(of: app.alertsUpdatedAt) { _, _ in state.refreshIncidents() }
            // The incidents the poller re-published feed the badge grouping.
            .onChange(of: state.incidentStations) { _, _ in refreshIncidentBadges() }
        }
        // Spec S1: the map screens show no navigation bar.
        .toolbar(.hidden, for: .navigationBar)
        // #101: a station dot opens the same sheet Explora shows for the place.
        .sheet(item: $selectedPlace) { place in
            ExplorePlaceDetailSheet(place: place)
                .environmentObject(app)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        // Spec S6, S7: the selected vehicle's or incident badge's glass card,
        // above the bottom accessory (the safe-area alignment keeps it clear
        // of it).
        .overlay(alignment: .bottom) {
            selectionCard
                .padding(.bottom, 8)
                .animation(AppMotion.smooth(reduceMotion: reduceMotion), value: selectedVehicle)
                .animation(AppMotion.smooth(reduceMotion: reduceMotion), value: selectedBadge)
        }
    }

    // MARK: - The v2 chrome (spec S1)

    /// The status capsule over the map (spec S2): freshness of the 30 s metro
    /// pass and connectivity in one glass capsule, like every map here (FGC
    /// keeps its own chip on its own screen). It joins the chrome when the
    /// first answer arrives, exactly the moment the old chip row appeared.
    @ViewBuilder
    private var statusCapsule: some View {
        if state.updatedAt != nil || state.lastPollFailed || !isOnline {
            FreshnessChip(
                updatedAt: state.updatedAt,
                lastAttemptFailed: state.lastPollFailed,
                feedEmpty: false
            )
            .transition(AppMotion.chipTransition)
        }
    }

    /// Whether the device currently has a network path (spec S2): when it
    /// does not, the status capsule shows the offline wording even before the
    /// poll answers.
    private var isOnline: Bool {
        ConnectivityMonitor.shared.isOnline
    }

    /// 44 pt glass location button, top-right of the map (spec S3, mockup
    /// `V2Main`). It keeps today's behavior: an undecided rider gets the
    /// permission request, and an authorized one gets the camera centered on
    /// their last fix — the system `MapUserLocationButton` behavior. An
    /// undecided or unknown span falls back to the street scale the metro map
    /// centers places at (spec S11). While the nearby sheet is open (spec
    /// S13) the button is filled with the accent color and a white glyph, on
    /// every map.
    private var locationButton: some View {
        Button {
            locate()
        } label: {
            if AppRouter.shared.isNearbyPresented {
                Image(systemName: "location.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color.accentColor))
                    .shadow(color: Color.black.opacity(0.35), radius: 8, y: 3)
            } else {
                Image(systemName: "location.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .glassEffect(in: Circle())
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("La meva ubicació")
    }

    private func locate() {
        guard LocationService.shared.authorization != .notDetermined else {
            LocationService.shared.requestWhenInUse()
            return
        }
        guard showsUserLocation, let point = LocationService.shared.location else {
            return
        }
        // The zoom-band span is kept current only at band changes on purpose
        // (a write per camera change would re-diff the whole map), so the
        // centering keeps the last known band and never zooms in beyond the
        // street scale.
        let span = max(latitudeSpan, Self.locateSpanFloor)
        withAnimation(AppMotion.smooth(reduceMotion: reduceMotion)) {
            cameraPosition = .region(
                MKCoordinateRegion(
                    center: CLLocationCoordinate2D(
                        latitude: point.latitude,
                        longitude: point.longitude
                    ),
                    span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span)
                )
            )
        }
        onLocate?()
    }

    /// Span floor of a user centering, the same street scale the metro map
    /// centers a focused place at (spec S11).
    private static let locateSpanFloor = 0.02

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
        } else if state.loadFailed {
            GlobalLoadFailedView {
                Task { await state.retryLoad() }
            }
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
        // Spec S1: the map fills the screen under the status bar; the chrome
        // overlays above keep their safe-area insets.
        .ignoresSafeArea(.container, edges: .top)
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
        .overlay(alignment: .bottomTrailing) {
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
                    .modifier(StationDotTap { open(dot.place) })
            }
        }
        ForEach(fgcStationsDots) { station in
            if let point = station.point {
                Annotation("", coordinate: CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)) {
                    StationDot(name: station.name, colorHex: "9E9E9E")
                        .modifier(StationDotTap {
                            open(Place(
                                kind: .fgcStation,
                                code: station.code,
                                name: station.name,
                                position: point,
                                lineCodes: [],
                                accessible: nil
                            ))
                        })
                }
            }
        }
    }

    /// Opens the station sheet of a tapped dot (#101). The catalog place wins
    /// when it is loaded: it lists every line serving the station.
    private func open(_ place: Place) {
        selectedVehicle = nil
        selectedBadge = nil
        selectedPlace = PlaceCatalogStore.shared.place(id: place.id) ?? place
    }

    /// Incident badges are not tied to the station band (spec S9): they are
    /// the one thing the overview zoom must show, so the lines-only first
    /// paint already carries them — and they stay on every closer band
    /// exactly as before. Depends only on the badge list derived off the
    /// render path, one per affected line, grouped on shared stations (D6).
    @MapContentBuilder
    private var incidentMarkersContent: some MapContent {
        ForEach(incidentBadges) { badge in
            Annotation("", coordinate: CLLocationCoordinate2D(latitude: badge.position.latitude, longitude: badge.position.longitude)) {
                Button {
                    selectedVehicle = nil
                    selectedBadge = badge
                } label: {
                    IncidentBadge(text: badge.badgeText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(globalBadgeAccessibilityLabel(badge))
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

    /// One live train: tappable, and the tap opens the glass card in place
    /// (spec S6), so the card shows the route data this screen can resolve
    /// without handing the rider to another map.
    private func vehicleAnnotation(_ vehicle: MapVehicle, operator mode: String) -> some MapContent {
        Annotation("", coordinate: CLLocationCoordinate2D(latitude: vehicle.position.latitude, longitude: vehicle.position.longitude)) {
            Button {
                selectedBadge = nil
                selectedVehicle = GlobalSelectedVehicle(vehicle: vehicle, operatorCode: mode)
            } label: {
                GlobalVehicleMarker(
                    vehicle: vehicle,
                    lineName: Self.vehicleLineName(of: vehicle, operator: mode),
                    cameraHeading: cameraHeading,
                    isEstimated: mode == AppModeCode.metro && isMetroVehicleEstimated(vehicle),
                    isSelected: selectedVehicle?.vehicle.id == vehicle.id
                )
            }
            .buttonStyle(.plain)
            // A train has to say "Tren" and its line to VoiceOver, as on
            // every map here (spec S8).
            .accessibilityLabel(vehicleAccessibilityLabel(vehicle, mode: mode))
        }
    }

    /// The code the marker glyph shows (spec S6, mockup `V3Markers`): there
    /// are no icons in Tot, so the line display name rides inside the circle
    /// ("L1", "S2"). Metro codes become their display name; FGC codes are
    /// already display codes ("S1").
    private static func vehicleLineName(of vehicle: MapVehicle, operator mode: String) -> String {
        guard mode == AppModeCode.metro else { return vehicle.lineCode }
        return MetroLine.line(forCode: vehicle.lineCode)?.displayName ?? vehicle.lineCode
    }

    /// Whether a metro train's marker ring is dashed (spec S6): the flag
    /// lives on the line state — its theoretical fleet only runs when the
    /// whole line's feed is empty — and `MapVehicle` does not carry it, so
    /// the line flag is the per-vehicle one.
    private func isMetroVehicleEstimated(_ vehicle: MapVehicle) -> Bool {
        state.lineStates[vehicle.lineCode]?.isTheoretical ?? false
    }

    /// Marker VoiceOver text: "Tren" plus line and destination, and — for FGC
    /// trains whose live feed reports cars (spec S18) — the occupancy summary.
    /// Metro vehicles have no occupancy feed, so their label stays as before.
    private func vehicleAccessibilityLabel(_ vehicle: MapVehicle, mode: String) -> String {
        if let line = MetroLine.line(forCode: vehicle.lineCode) {
            return String(localized: "Tren \(line.displayName) cap a \(vehicle.label)")
        }
        var label = String(localized: "Tren \(vehicle.lineCode) cap a \(vehicle.label)")
        if mode == AppModeCode.fgc,
           let train = fgc.trains.first(where: { $0.id == vehicle.id }),
           let occupancy = FGCOccupancy.summary(train) {
            label += ". \(occupancy)"
        }
        return label
    }

    // MARK: - Incident badges (spec S7, D6)

    /// Re-derives the grouped incident badges from the shared incident
    /// stations. Never called from the render path: the incidents change when
    /// the alerts or the poll pass refresh, and the topology change provides
    /// the station order — every trigger is a throttled, human-scale event.
    /// A selection whose badge vanished quietly closes its card.
    private func refreshIncidentBadges() {
        incidentBadges = GlobalIncidentBadges.badges(from: state.incidentStations) { lineCode, stationID in
            state.lineStates[lineCode]?.stations.first { StationGroupKey.key(for: $0) == stationID }?.orderInLine
        }
        if let badge = selectedBadge, !incidentBadges.contains(badge) {
            selectedBadge = nil
        }
    }

    /// VoiceOver text of an incident badge (mockup `V3Tot`): the affected
    /// lines by display name, with the tap hint when the badge groups
    /// several of them.
    private func globalBadgeAccessibilityLabel(_ badge: GlobalIncidentBadge) -> String {
        switch badge.lineNames.count {
        case 1:
            return String(localized: "Servei afectat a la \(badge.lineNames[0])")
        case 2:
            return String(
                localized: "Servei afectat a la \(badge.lineNames[0]) i la \(badge.lineNames[1]). Toca per veure-les"
            )
        case let count:
            return String(localized: "Servei afectat a \(count) línies")
        }
    }

    // MARK: - The glass cards (spec S6, S7)

    /// The card of the moment: a vehicle's, or an incident badge's — a tap of
    /// one closes the other, so only one is ever open.
    @ViewBuilder
    private var selectionCard: some View {
        if let selected = selectedVehicle {
            vehicleCard(selected)
        } else if let badge = selectedBadge {
            incidentBadgeCard(badge)
        }
    }

    /// The selected vehicle's card (spec S6): the line badge, the
    /// destination, the rows the operator's state can resolve, and where the
    /// position comes from.
    private func vehicleCard(_ selected: GlobalSelectedVehicle) -> some View {
        MapGlassCard(
            badgeText: Self.vehicleLineName(of: selected.vehicle, operator: selected.operatorCode),
            badgeColorHex: selected.vehicle.colorHex,
            title: String(localized: "Cap a \(selected.vehicle.label)"),
            onClose: { selectedVehicle = nil }
        ) {
            VStack(alignment: .leading, spacing: 8) {
                if selected.operatorCode == AppModeCode.metro {
                    GlobalVehicleCardRows.Metro(
                        lineCode: selected.vehicle.lineCode,
                        vehicleID: selected.vehicle.id,
                        isEstimated: isMetroVehicleEstimated(selected.vehicle)
                    )
                } else {
                    GlobalVehicleCardRows.FGC(vehicleID: selected.vehicle.id)
                }
                // What a tap used to do before the card (spec S8, S10): hand
                // the rider to the operator's map with the vehicle focused.
                Button {
                    AppRouter.shared.open(.vehicle(
                        operator: selected.operatorCode,
                        lineCode: selected.vehicle.lineCode,
                        vehicleID: selected.vehicle.id
                    ))
                } label: {
                    Label("Veure a la línia", systemImage: "arrow.up.right.circle")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    /// The open badge's card (spec S7, D6): every service alert behind the
    /// badge with its time, and the jump to the alerts tab.
    private func incidentBadgeCard(_ badge: GlobalIncidentBadge) -> some View {
        MapGlassCard(
            badgeText: badge.badgeText,
            badgeColorHex: "FF9F0A",
            title: badge.stationName,
            onClose: { selectedBadge = nil }
        ) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(badge.alerts) { alert in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(AlertText.effect(for: alert) ?? String(localized: "Incidència"))
                            .font(.subheadline.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        if let time = Self.alertTimeText(alert) {
                            Text(time)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Button {
                    selectedBadge = nil
                    AppRouter.shared.selectedTab = .alerts
                } label: {
                    Label("Veure a Avisos", systemImage: "exclamationmark.bubble")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(hex: "FF9F0A"))
            }
        }
    }

    /// Begin, end or the range between them, whichever the feed provides —
    /// the same wording the incident sheet shows (spec S7).
    private static func alertTimeText(_ alert: ServiceAlert) -> String? {
        switch (alert.beginDate, alert.endDate) {
        case let (begin?, end?):
            return "\(Self.alertDay(begin)) – \(Self.alertDay(end))"
        case let (begin?, nil):
            return Self.alertDay(begin)
        case let (nil, end?):
            return Self.alertDay(end)
        case (nil, nil):
            return nil
        }
    }

    private static func alertDay(_ date: Date) -> String {
        alertDayFormatter.string(from: date)
    }

    /// An alert's calendar day, "12/03/2026", pinned to the Gregorian calendar
    /// and a fixed locale like the metro map's formatter: the device's calendar
    /// would render a Thai Buddhist or Japanese year instead of the feed's
    /// (#54).
    private static let alertDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "dd/MM/yyyy"
        return formatter
    }()

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

/// Makes a 10 pt station dot tappable through a 32 pt target (#101). Kept out
/// of `StationDot` so the dot stays a plain `Equatable` value.
private struct StationDotTap: ViewModifier {
    let action: () -> Void

    func body(content: Content) -> some View {
        content
            .frame(width: 44, height: 44)
            .contentShape(Circle())
            .onTapGesture(perform: action)
            .accessibilityAddTraits(.isButton)
    }
}

/// One live train on the global map (spec S6, mockup `V3Markers`): the
/// unified marker — a solid circle in the line color with the line code in
/// place of a pictogram, the heading wedge and the dashed estimate ring for
/// metro timetable positions — plus the selected vehicle's destination chip
/// below. `Equatable` so a 10 Hz glide tick that changed nothing visible
/// skips the body.
private struct GlobalVehicleMarker: View, Equatable {
    let vehicle: MapVehicle
    /// "L1", "L9N" or an FGC code ("S1"): the glyph of the unified marker
    /// in Tot is the line code, never a pictogram (spec S6).
    let lineName: String
    let cameraHeading: Double
    let isEstimated: Bool
    let isSelected: Bool

    var body: some View {
        VehicleMarkerView(
            colorHex: vehicle.colorHex,
            glyph: .code(lineName),
            headingDegrees: vehicle.heading - cameraHeading,
            isEstimated: isEstimated,
            isSelected: isSelected,
            size: 28
        )
        .overlay(alignment: .bottom) {
            if isSelected {
                Text(vehicle.label)
                    .font(.caption2.bold())
                    .lineLimit(1)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color(hex: "2C2E34").opacity(0.85)))
                    .overlay(Capsule().stroke(Color.white.opacity(0.16), lineWidth: 1))
                    .fixedSize()
                    .offset(y: 24)
            }
        }
    }
}

/// The vehicle a glass card belongs to (spec S6): the live map value plus the
/// operator section the tap came from, which decides what rows the card can
/// resolve. `Equatable` because the card overlay animates on it.
private struct GlobalSelectedVehicle: Equatable {
    let vehicle: MapVehicle
    /// "metro" or "fgc" — `AppModeCode` values.
    let operatorCode: String
}

/// The selected vehicle's glass card rows, read live from the shared states
/// by the train id so the card tracks the poll like the sheets do (spec S6).
private enum GlobalVehicleCardRows {
    /// Metro rows (spec S6): the next station with its countdown when the
    /// train is still in the feed, then where the position comes from — the
    /// same copies the metro train sheet shows.
    struct Metro: View {
        let lineCode: String
        let vehicleID: String
        let isEstimated: Bool

        private var lineState: LineState? {
            GlobalNetworkState.shared.lineStates[lineCode]
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                if let lineState,
                   let position = lineState.vehiclePosition(id: vehicleID),
                   let station = lineState.station(forCode: position.nextStationCode) {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(Color(hex: lineState.line.colorHex))
                            .frame(width: 8, height: 8)
                        Text(station.name)
                            .font(.subheadline)
                        Spacer(minLength: 8)
                        Text(Arrival.countdownText(seconds: position.secondsToArrival))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(
                        "Pròxima estació \(station.name), arriba en \(Arrival.countdownText(seconds: position.secondsToArrival))"
                    )
                }
                VehiclePositionSource(
                    isEstimated: isEstimated,
                    estimatedText: String(localized: "Posició estimada a partir de l'horari")
                )
            }
        }
    }

    /// FGC rows (spec S6, D1: no minutes — the feed publishes neither):
    /// the stop the train serves next and its punctuality, then where the
    /// position comes from. FGC positions are GPS live data, never estimated.
    struct FGC: View {
        let vehicleID: String

        private var state: FGCNetworkState { FGCNetworkState.shared }

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                if let train = state.trains.first(where: { $0.id == vehicleID }) {
                    if let stopCode = train.stoppedAtStopCode {
                        Label("Aturat a \(stationName(for: stopCode))", systemImage: "pause.circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else if let stopCode = train.nextStopCodes.first {
                        Label("Pròxima: \(stationName(for: stopCode))", systemImage: "arrow.right.circle")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Text(train.isOnTime ? "Puntual" : "Amb retard")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(train.isOnTime ? Color.green : Color(hex: "F59E0B"))
                }
                VehiclePositionSource(isEstimated: false, estimatedText: "")
            }
        }

        /// Station name of a stop code, falling back to the code when the
        /// catalog does not know it, exactly as the train sheet does.
        private func stationName(for code: String) -> String {
            state.stations.first { $0.code == code }?.name ?? code
        }
    }
}

/// Error state of the global map (spec S8): a load that left the map empty
/// says so instead of spinning forever, with a retry that re-runs the
/// topology pass.
private struct GlobalLoadFailedView: View {
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No s'ha pogut carregar la xarxa")
                .font(.callout)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Reintenta", action: onRetry)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
