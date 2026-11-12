import MapKit
import SwiftUI

/// Live map of one line: physical route as a polyline overlay, stations and
/// computed train positions as annotations.
@MainActor
struct MapScreen: View {
    /// Whether metro is the mode on screen (spec S13). `RootView` keeps all
    /// four map screens mounted (spec S12), so this flag — and not the view's
    /// lifecycle — is what says whether the screen may load and poll: an
    /// off-screen mode does neither, and coming back resumes on the retained
    /// `LineState` without refetching its topology.
    let isActive: Bool
    /// Hook for the nearby sheet (spec S13, T5): called after the location
    /// button centers the camera on the rider. Defaults to nothing.
    var onLocate: (() -> Void)? = nil
    @EnvironmentObject private var app: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The selection is persisted under the key `AppRouter` writes for a
    /// `.line` or `.vehicle` focus, so a router destination selects the line
    /// by changing the same stored value the picker chips write (specs S10, S11).
    @AppStorage("metroSelectedLine") private var selectedLineCode = MetroLine.allLines[0].code
    @State private var lineState: LineState?
    /// Every line state this screen has built, keyed by line code (spec S4):
    /// switching L1→L2→L1 or coming back to the tab repaints the line from
    /// memory instead of refetching its stations and geometry.
    @State private var lineStates: [String: LineState] = [:]
    /// What the map draws that does not depend on the 10 Hz position tick: the
    /// line polyline, the terminal markers and the incident runs with their
    /// overlay coordinates (spec S8). Re-derived from the topology and the
    /// alerts feed, never while `body` runs.
    @State private var mapOverlay = MetroMapOverlay()
    @State private var selectedStation: Station?
    /// Train whose sheet is open (spec S10). A snapshot copy: the sheet reads
    /// the live position from the line state by id, like the FGC map.
    @State private var selectedTrain: TrainPosition?
    /// Vehicle the rider selected by tapping its marker (spec S6): tapping
    /// again, closing the card or changing the line deselects it. A user
    /// action, so it may re-diff; nothing on the 10 Hz position path touches
    /// it.
    @State private var selectedVehicleID: String?
    /// Alert id whose service card is open through its run's badge (spec S7).
    @State private var selectedIncidentAlertID: String?
    /// Train the camera is following, or nil (spec S10).
    @State private var followingTrainID: String?
    /// Where the camera was commanded to last, so the continuous callback can
    /// tell our own follow animation from a pan by the rider (spec S10).
    @State private var followAnchor: GeoPoint?
    /// Span the camera follows with: kept current by every camera change so
    /// re-centering never zooms (spec S10).
    @State private var cameraSpan = MapScreen.barcelonaRegion.span
    /// Place focus whose station centering waits for the line's stations.
    @State private var pendingPlace: Place?
    /// Vehicle focus waiting for its train to appear in the feed (spec S11).
    @State private var pendingVehicleID: String?
    // Named type instead of `Self` on purpose: a stored-property initializer has
    // no instance context, so the spelled-out type name is the form that is
    // guaranteed to compile.
    @State private var cameraPosition: MapCameraPosition = .region(MapScreen.barcelonaRegion)
    /// Which station markers the camera zoom calls for (issue #93): above the
    /// `MetroStationZoom` threshold stations are small dots with no capsule
    /// and no name, so the whole-line view of a long line does not stack the
    /// capsules over the trains and the incident marks. The initial value
    /// matches the initial camera region; `MetroStationZoom`'s hysteresis
    /// decides every change afterwards, and the band is stored only when it
    /// changes, so a camera wobble around the threshold never re-diffs the
    /// map content.
    @State private var stationBand: MetroStationBand = MetroStationZoom.band(
        forLatitudeSpan: MapScreen.barcelonaRegion.span.latitudeDelta
    )

    private var selectedLine: MetroLine {
        MetroLine.line(forCode: selectedLineCode) ?? MetroLine.allLines[0]
    }

    /// Navigation intent source: `.line`, `.place` and `.vehicle` focuses
    /// addressed to metro are handled here (spec S11).
    private var router: AppRouter { AppRouter.shared }
    /// Device location behind the user dot (spec S11).
    private var location: LocationService { LocationService.shared }

    private var isLocationAuthorized: Bool {
        location.authorization == .authorizedWhenInUse || location.authorization == .authorizedAlways
    }

    private var isLocationNotDetermined: Bool {
        location.authorization == .notDetermined
    }

    /// Whether the device currently has a network path (spec S2): when it
    /// does not, the status capsule shows the offline wording even before the
    /// line's first poll answers.
    private var isOnline: Bool {
        ConnectivityMonitor.shared.isOnline
    }

    var body: some View {
        NavigationStack {
            ZStack {
                mapArea
                    // The placeholder and the map swap with a short fade when
                    // the line's state first arrives (polish pass) and when
                    // its stations do: until then the placeholder stays up
                    // instead of an empty map (spec S2).
                    .animation(AppMotion.smooth(reduceMotion: reduceMotion), value: mapAreaPhase)
            }
            // Spec S1: no header — the mode selector, the line chips and the
            // counts move to the bottom accessory, the map fills the screen
            // under the status bar (`ignoresSafeArea` on the map only), and
            // the v2 chrome lives in overlays: the status capsule top-left and
            // the glass location button top-right.
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
            .overlay(alignment: .top) {
                if let state = lineState, state.isFeedEmpty {
                    // Below the capsule instead of colliding with it (spec S1).
                    NoRealtimeDataCard(compact: true, theoretical: state.isTheoretical)
                        .padding(.horizontal, 16)
                        .padding(.top, 52)
                        .transition(AppMotion.chipTransition)
                }
            }
            // The capsule joins the chrome the moment the line's state exists:
            // fade and shrink it in instead of a pop (polish pass), the same
            // way the old chip row did.
            .animation(AppMotion.smooth(reduceMotion: reduceMotion), value: lineState != nil)
            .animation(AppMotion.smooth(reduceMotion: reduceMotion), value: lineState?.isFeedEmpty)
            // Changing the line is a selection, so it clicks (polish pass).
            .sensoryFeedback(.selection, trigger: selectedLineCode)
            // Loader task comment (unchanged, spec S13): the task must live on
            // the always-visible container; keyed on the mode as well as on
            // the line, so leaving metro cancels the poll and returning
            // resumes with the state it kept.
            .task(id: MetroLoadKey(isActive: isActive, lineCode: selectedLineCode)) {
                guard isActive else { return }
                guard let client = app.client else { return }
                // Spec S4: a line loaded on this screen is reused, so a line
                // switch or a return to the tab repaints from memory and only
                // resumes polling. `run()` loads the topology the first time.
                let state = cachedLineState(for: selectedLine, client: client)
                self.lineState = state
                // Spec S8: a reused line already has its stations, so its
                // overlay is derived before the map draws instead of one
                // change later.
                refreshMapOverlay(for: state)
                await state.run()
            }
            // The map's incident overlays and coordinates come from exactly
            // three inputs: the line's stations, its geometry and the alerts
            // feed. Deriving them on the always-visible container — and not
            // from `lineMap` — also covers the stations that arrive while the
            // loader is still up (spec S8).
            .onChange(of: lineState?.stations) { _, _ in
                refreshMapOverlayIfPossible()
            }
            .onChange(of: lineState?.geometry) { _, _ in
                refreshMapOverlayIfPossible()
            }
            // `alertsUpdatedAt` moves on every successful alerts poll, which is
            // also when an alert that ran out stops being drawn.
            .onChange(of: app.alertsUpdatedAt) { _, _ in
                refreshMapOverlayIfPossible()
            }
            // A focus set while the map is already open arrives through the
            // change; one set from another tab is picked up on appear (S11).
            .onAppear {
                handlePendingFocus()
            }
            .onChange(of: router.pendingFocus) { _, _ in
                handlePendingFocus()
            }
            .onChange(of: selectedLineCode) { _, _ in
                // A new line is a new subject: drop the old train, its follow,
                // the vehicle selection, the station sheet and any incident
                // card (S10, S6, S7). The station sheet re-derives its line
                // from the selection, so keeping it open would show the new
                // line's data for the old station (#52).
                selectedTrain = nil
                followingTrainID = nil
                selectedVehicleID = nil
                selectedIncidentAlertID = nil
                selectedStation = nil
            }
            // The interchange capsules (D4) read the places catalog, which may
            // arrive after the line's topology: a loaded catalog re-derives
            // the overlay so late matches still draw (spec S6).
            .onChange(of: PlaceCatalogStore.shared.places.count) { _, _ in
                refreshMapOverlayIfPossible()
            }
            // The selected subject's glass card sits above the tab bar and the
            // accessory, inside the safe area (spec S6, S7, mockup `V3Metro`).
            // One card at a time: the incident badge and the vehicle marker
            // deselect each other.
            .overlay(alignment: .bottom) {
                if let alertID = selectedIncidentAlertID,
                   let alert = app.alerts.first(where: { $0.id == alertID }) {
                    incidentCard(for: alert)
                } else if let vehicleID = selectedVehicleID, let state = lineState,
                          let train = state.vehiclePosition(id: vehicleID) {
                    vehicleCard(for: train, state: state)
                }
            }
        }
        // Spec S1: the map screens show no navigation bar; the map fills the
        // screen and the sheets stay presented by the stack underneath.
        .toolbar(.hidden, for: .navigationBar)
        // The station sheet is presented by the stack itself and declares its
        // detents here instead of inside the presented view: presenting it from
        // a view nested in the stack is what left its first rows under the
        // navigation bar in build 23 (spec S9).
        .sheet(item: $selectedStation) { station in
            StationDetailView(station: station, line: selectedLine)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        // The train sheet (spec S10): the stack declares the detents, and
        // closing it stops the follow, exactly like the FGC map.
        .sheet(item: $selectedTrain, onDismiss: { followingTrainID = nil }) { train in
            if let state = lineState {
                MetroTrainSheet(trainID: train.id, state: state, followingTrainID: $followingTrainID)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    /// The status capsule over the map (spec S2): freshness of the line data
    /// and connectivity in one glass capsule. Online it waits for the line's
    /// state, as the old chip row did; offline it is always there, because the
    /// saved-data wording is what the map needs before the first poll answers.
    @ViewBuilder
    private var statusCapsule: some View {
        if let state = lineState {
            FreshnessChip(lineState: state)
                .transition(AppMotion.chipTransition)
        } else if !isOnline {
            FreshnessChip(updatedAt: nil, lastAttemptFailed: false, feedEmpty: false)
                .transition(AppMotion.chipTransition)
        }
    }

    /// 44 pt glass location button, top-right of the map (spec S3, mockup
    /// `V2Main`). It keeps today's behavior: an undecided rider gets the
    /// permission request the map used to offer in its own button, an
    /// authorized one gets the camera centered on their last fix at the zoom
    /// already on screen — the system `MapUserLocationButton` behavior.
    /// `onLocate` is the T5 hook for the nearby sheet, and while the sheet is
    /// open (spec S13) the button draws filled: accent background, white glyph.
    private var locationButton: some View {
        Button {
            locate()
        } label: {
            Image(systemName: "location.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(router.isNearbyPresented ? Color.white : Color.accentColor)
                .frame(width: 44, height: 44)
                .background {
                    if router.isNearbyPresented {
                        Circle().fill(Color.accentColor)
                    }
                }
                .glassEffect(in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("La meva ubicació")
    }

    private func locate() {
        if isLocationNotDetermined {
            // No decision taken yet: one tap asks for permission (spec S11).
            location.requestWhenInUse()
            return
        }
        guard isLocationAuthorized else { return }
        location.start()
        guard let point = location.location else { return }
        withAnimation(AppMotion.smooth(reduceMotion: reduceMotion)) {
            cameraPosition = .region(
                MKCoordinateRegion(
                    center: CLLocationCoordinate2D(
                        latitude: point.latitude,
                        longitude: point.longitude
                    ),
                    span: cameraSpan
                )
            )
        }
        onLocate?()
    }

    /// The state of one line, built on first use and kept afterwards (spec S4).
    /// The map is the only screen with this cache: bus and FGC keep their own
    /// lifecycle.
    private func cachedLineState(for line: MetroLine, client: TMBClient) -> LineState {
        if let existing = lineStates[line.code] { return existing }
        let created = LineState(line: line, client: client)
        lineStates[line.code] = created
        return created
    }

    /// What `mapArea` draws right now: the loader or the map. One value instead
    /// of the separate checks the view makes, so the fade between the two keeps
    /// the single curve it had when it was keyed on "the state exists"
    /// (spec S2).
    private enum MapAreaPhase: Equatable {
        case loading
        case map
    }

    private var mapAreaPhase: MapAreaPhase {
        guard app.missingCredentialsMessage == nil, let state = lineState else { return .loading }
        return Self.showsMap(for: state) ? .map : .loading
    }

    /// Whether the map is drawn instead of the loader (spec S2): as soon as the
    /// line has stations, or when it has an error to show — the failure notice
    /// has always been an overlay of the map itself, so the loader must not
    /// swallow it.
    private static func showsMap(for state: LineState) -> Bool {
        !state.stations.isEmpty || state.errorMessage != nil
    }

    @ViewBuilder
    private var mapArea: some View {
        if let message = app.missingCredentialsMessage {
            ConfigurationNotice(message: message)
        } else if let client = app.client, let state = lineState, Self.showsMap(for: state) {
            lineMap(state: state, client: client)
                .transition(.opacity)
        } else {
            MapLoadingPlaceholder()
                .transition(.opacity)
        }
    }

    @ViewBuilder
    private func lineMap(state: LineState, client: TMBClient) -> some View {
        // Everything drawn outside the position markers comes from
        // `mapOverlay`, derived when the topology or the alerts changed
        // (spec S8): the grouping of the incidents, the terminal stations and
        // the map coordinates of every polyline are never recomputed here.
        Map(position: $cameraPosition) {
            if mapOverlay.line.count >= 2 {
                MapPolyline(coordinates: mapOverlay.line)
                    .stroke(Color(hex: selectedLine.colorHex), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            }
            // Keyed by position in the published list, the rule the diagram
            // already follows: a station code is not unique enough (a line can
            // list the same station twice) and the operator id may be absent,
            // so `ForEach(state.stations)` produced duplicate identities and
            // the annotation glitches that come with them (#59).
            ForEach(Array(state.stations.enumerated()), id: \.offset) { _, station in
                // No name on the annotation title while zoomed out (issue
                // #93): the dot band draws no capsule and no name.
                Annotation(stationBand == .dots ? "" : station.name, coordinate: CLLocationCoordinate2D(latitude: station.latitude, longitude: station.longitude)) {
                    Button {
                        selectedStation = station
                    } label: {
                        if stationBand == .dots {
                            // Zoomed out (issue #93): the small dot of the
                            // global map, with the station's name kept for
                            // VoiceOver and the same 44 pt touch target the
                            // detailed markers have, so the station sheet
                            // stays reachable at every zoom.
                            ZoomedOutStationDot(colorHex: selectedLine.colorHex)
                                .accessibilityLabel("Estació \(station.name)")
                        } else if mapOverlay.interchangeLineCodes[station.code]?.isEmpty == false {
                            InterchangeCapsule()
                        } else {
                            HollowStationDot(
                                colorHex: selectedLine.colorHex,
                                isTerminal: mapOverlay.terminalCodes.contains(station.code)
                            )
                        }
                    }
                }
            }
            // Each run of consecutive affected stations overlays the track
            // with a dotted line in the line's own colour — never red, the
            // colour stays the line's (spec S7, mockup `V3Markers`).
            ForEach(mapOverlay.incidentRuns) { incidentRun in
                if incidentRun.coordinates.count >= 2 {
                    MapPolyline(coordinates: incidentRun.coordinates)
                        .stroke(
                            Color(hex: selectedLine.colorHex).opacity(0.9),
                            style: StrokeStyle(lineWidth: 5, lineCap: .round, dash: [0.1, 9])
                        )
                }
            }
            // ONE amber badge per affected run, at the run's middle station
            // (spec S7, mockup `V3Metro`). Empty title: the badge carries the
            // line and the accessibility label names the alert.
            ForEach(mapOverlay.incidentBadges) { badge in
                Annotation("", coordinate: CLLocationCoordinate2D(latitude: badge.latitude, longitude: badge.longitude)) {
                    Button {
                        // The badge and the vehicle card clear each other: one
                        // glass card at a time (spec S6, S7).
                        selectedVehicleID = nil
                        selectedIncidentAlertID = badge.alertID
                    } label: {
                        IncidentBadge(text: badge.text)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Servei afectat a la línia \(badge.text)")
                }
            }
            // Small grey icon next to every station with a facility alert out
            // of service, slightly offset so the station dot stays visible
            // (spec S7). Not tappable: the alert's text lives in the Parades
            // and Avisos screens.
            // Same rule for the facility marks: their identity is the
            // position in the list, not the station code the mark carries
            // (#59).
            ForEach(Array(mapOverlay.facilityStations.enumerated()), id: \.offset) { _, mark in
                Annotation("", coordinate: CLLocationCoordinate2D(latitude: mark.latitude, longitude: mark.longitude)) {
                    FacilityStationIcon(kind: mark.kind)
                        .offset(x: 12, y: -12)
                        .accessibilityLabel(facilityAccessibilityText(mark, state: state))
                }
            }
            ForEach(state.positions) { position in
                // Empty title: the marker speaks for itself and the selected
                // vehicle's glass card carries the destination (spec S6).
                Annotation("", coordinate: CLLocationCoordinate2D(latitude: position.position.latitude, longitude: position.position.longitude)) {
                    Button {
                        // Tapping selects the vehicle and closes any incident
                        // card; tapping again deselects (spec S6). The train
                        // sheet stays for `AppRouter` `.vehicle` focuses.
                        selectedIncidentAlertID = nil
                        selectedVehicleID = selectedVehicleID == position.id ? nil : position.id
                    } label: {
                        vehicleMarker(for: position)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Tren de la \(trainLine(for: position).displayName) cap a \(position.destination)")
                }
            }
            // The rider's own dot once permission was granted (spec S11).
            if isLocationAuthorized {
                UserAnnotation()
            }
        }
        .mapStyle(.standard(elevation: .flat))
        // Spec S1: the map fills the screen under the status bar; the chrome
        // overlays above keep their safe-area insets.
        .ignoresSafeArea(.container, edges: .top)
        // Pan detection for the follow (spec S10): a change whose center is
        // not near the point we last commanded is the rider moving the map,
        // so the camera releases the train. Zoom keeps the follow.
        .onMapCameraChange(frequency: .continuous) { context in
            cameraSpan = context.region.span
            // Issue #93: the station band goes through `MetroStationZoom`'s
            // hysteresis and is stored only when it changes, so the camera
            // callbacks cannot re-diff the map content on their own.
            let nextBand = MetroStationZoom.band(
                forLatitudeSpan: context.region.span.latitudeDelta,
                previous: stationBand
            )
            if nextBand != stationBand {
                stationBand = nextBand
            }
            guard followingTrainID != nil, let anchor = followAnchor else { return }
            let tolerance = max(Self.followPanToleranceDegrees, cameraSpan.latitudeDelta * 0.05)
            let center = context.region.center
            if abs(center.latitude - anchor.latitude) > tolerance
                || abs(center.longitude - anchor.longitude) > tolerance {
                followingTrainID = nil
            }
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
        .onAppear {
            fitCamera(to: state.stations)
        }
        .onChange(of: state.stations.map(\.code)) { _, _ in
            fitCamera(to: state.stations)
        }
        // The glide updates `positions` at 10 Hz: re-center the followed
        // train, and open the sheet of a `.vehicle` focus as soon as its
        // train exists (specs S10, S11).
        .onChange(of: state.positions) { _, positions in
            followTrain(in: positions)
            resolvePendingVehicleIfNeeded(in: positions)
        }
        // No content-keyed `.animation` on the station set: animating it made
        // every annotation of a line switch fly in, which read as a doubled
        // annotation layer (map-perf S14b). Annotations pop in like the FGC
        // map already does; the placeholder fade (`mapAreaPhase`) stays.
    }

    /// Refit the camera on the stations of the line currently shown, so a long
    /// line such as L5 is not cut off by the fixed Barcelona region (S5).
    /// An empty station list leaves the camera where it is.
    private func fitCamera(to stations: [Station]) {
        // A `.place` focus owns the camera until its station is on screen:
        // the fit of the new line's topology is what resolves it (S11).
        if pendingPlace != nil {
            resolvePendingPlace(in: stations)
            return
        }
        guard let region = Self.region(fitting: stations) else { return }
        withAnimation(.easeInOut(duration: 0.35)) {
            cameraPosition = .region(region)
        }
    }

    // MARK: - Incidents on the map (S7)

    /// #99: VoiceOver names where the mark is — the station it sits next to
    /// — not the per-line station code the mark carries. Falls back to no
    /// station name when the line state no longer lists that code.
    private func facilityAccessibilityText(
        _ mark: FacilityStationMark,
        state: LineState
    ) -> String {
        if let name = state.stations.first(where: { $0.code == mark.stationCode })?.name {
            return "Incidència d'instal·lació a l'estació \(name)"
        }
        return "Incidència d'instal·lació en una estació"
    }

    /// Everything the map draws besides the position markers, derived from the
    /// line's topology and the alerts feed (spec S8). Called when either
    /// changes, never from the 10 Hz render path: the incident grouping, the
    /// track slicing of every run, the badge placement and the multiple
    /// `GeoPoint` → `CLLocationCoordinate2D` mappings happen once per change
    /// instead of ten times a second.
    ///
    /// `IncidentIndex` reads the clock, so an alert that runs out stops being
    /// drawn at the next alerts poll (once a minute, the granularity
    /// `GlobalNetworkState.refreshIncidents` already has) rather than on the
    /// next frame.
    private func refreshMapOverlay(for state: LineState) {
        let geometry = state.geometry
        let incidents = IncidentIndex.incidents(
            for: app.alerts,
            stations: state.stations,
            lineCode: state.line.code
        )
        // Severity split (S7): service alerts own the dotted runs and the
        // badges, facility alerts draw their small grey icon per station.
        var serviceIncidents: [Int: [StationIncident]] = [:]
        var facilityStations: [FacilityStationMark] = []
        for station in state.stations {
            guard let list = incidents[station.code], !list.isEmpty else { continue }
            let facilityList = list.filter { ParadesTimeline.isFacilityIncident($0) }
            let serviceList = list.filter { !ParadesTimeline.isFacilityIncident($0) }
            if !facilityList.isEmpty {
                facilityStations.append(
                    FacilityStationMark(
                        stationCode: station.code,
                        kind: facilityList[0].kind,
                        latitude: station.latitude,
                        longitude: station.longitude
                    )
                )
            }
            if !serviceList.isEmpty {
                serviceIncidents[station.code] = serviceList
            }
        }
        var runs: [IncidentRunLayer] = []
        var badges: [IncidentRunBadge] = []
        for overlay in IncidentSegments.overlays(
            stations: state.stations,
            incidents: serviceIncidents,
            geometry: geometry
        ) {
            if overlay.points.count >= 2 {
                runs.append(
                    IncidentRunLayer(run: overlay.run, coordinates: Self.mapCoordinates(of: overlay.points))
                )
            }
            if let badge = IncidentBadgePlacement.badge(
                for: overlay.run,
                lineDisplayName: state.line.displayName,
                serviceIncidents: serviceIncidents
            ) {
                badges.append(badge)
            }
        }
        mapOverlay = MetroMapOverlay(
            line: geometry.map { Self.mapCoordinates(of: $0.points) } ?? [],
            terminalCodes: Self.terminalStationCodes(in: state.stations),
            incidentRuns: runs,
            incidentBadges: badges,
            facilityStations: facilityStations,
            interchangeLineCodes: Self.interchangeLineCodes(
                stations: state.stations,
                lineCode: state.line.code
            )
        )
    }

    /// Metro–metro interchange lines per station code (D4), read from the
    /// places catalog through `StationInterchange`: the same source
    /// `MapScreen` matches a `Place` focus against.
    private static func interchangeLineCodes(
        stations: [Station],
        lineCode: String
    ) -> [Int: [String]] {
        let places = PlaceCatalogStore.shared.places
        guard !places.isEmpty else { return [:] }
        var result: [Int: [String]] = [:]
        for station in stations {
            let codes = StationInterchange.metroLineDisplayNames(
                for: station,
                places: places,
                lineCode: lineCode
            )
            if !codes.isEmpty {
                result[station.code] = codes
            }
        }
        return result
    }

    /// Re-derives the overlay of the line on screen, or clears it while no line
    /// state exists: the change triggers live on the always-visible container,
    /// where the state may still be nil (spec S8).
    private func refreshMapOverlayIfPossible() {
        guard let state = lineState else {
            mapOverlay = MetroMapOverlay()
            return
        }
        refreshMapOverlay(for: state)
    }

    /// Map coordinates of a polyline (spec S8): the one place the `GeoPoint` →
    /// `CLLocationCoordinate2D` conversion happens, so it runs when a geometry
    /// changes and never on a position tick.
    private static func mapCoordinates(of points: [GeoPoint]) -> [CLLocationCoordinate2D] {
        points.map { point in
            CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
        }
    }

    // MARK: - Selected subject cards (S6, S7)

    /// The marker of one train (spec S6, mockup `V3Markers`): the unified
    /// marker in the line's colour with the heading wedge; the selected train
    /// gets the halo plus a small glass label with its destination under the
    /// marker. The overlay adds nothing to the layout frame, so MapKit keeps
    /// centering the annotation on the coordinate.
    private func vehicleMarker(for position: TrainPosition) -> some View {
        VehicleMarkerView(
            colorHex: trainLine(for: position).colorHex,
            glyph: .train,
            headingDegrees: position.heading,
            isEstimated: position.isTheoretical,
            isSelected: selectedVehicleID == position.id
        )
        .overlay(alignment: .bottom) {
            if selectedVehicleID == position.id {
                Text(position.destination)
                    .font(.caption2.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .glassEffect(in: Capsule())
                    .fixedSize()
                    .offset(y: 22)
            }
        }
    }

    /// Glass card of the selected train (spec S6, mockup `V3Metro`): the line
    /// badge, the destination, the next stop with its countdown when the data
    /// exists (never a new request: the row reads the same positions and
    /// stations the screen already holds), and where the position comes from.
    private func vehicleCard(for train: TrainPosition, state: LineState) -> some View {
        let line = trainLine(for: train)
        return MapGlassCard(
            badgeText: line.displayName,
            badgeColorHex: line.colorHex,
            title: train.destination.isEmpty ? "Destí desconegut" : "Cap a \(train.destination)",
            onClose: { selectedVehicleID = nil }
        ) {
            VStack(alignment: .leading, spacing: 8) {
                if let station = state.station(forCode: train.nextStationCode) {
                    Text("Pròxima: \(station.name) · \(Arrival.countdownText(seconds: train.secondsToArrival))")
                        .font(.subheadline.weight(.medium))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(
                            "Pròxima \(station.name), arriba en \(Arrival.countdownText(seconds: train.secondsToArrival))"
                        )
                }
                VehiclePositionSource(
                    isEstimated: train.isTheoretical,
                    estimatedText: "Posició estimada a partir de l'horari"
                )
                // The existing train sheet: next stations and "follow"
                // stay reachable from a plain tap (no regression of S8).
                Button {
                    selectedTrain = train
                } label: {
                    Label("Més detalls", systemImage: "info.circle")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    /// Glass card of a run's amber badge (spec S7, mockup `V3Metro`): the
    /// alert's text and time and a jump to the Avisos tab. The badge is
    /// tapped, so the card carries the line itself.
    private func incidentCard(for alert: ServiceAlert) -> some View {
        MapGlassCard(
            badgeText: selectedLine.displayName,
            badgeColorHex: selectedLine.colorHex,
            title: "Servei afectat",
            onClose: { selectedIncidentAlertID = nil }
        ) {
            VStack(alignment: .leading, spacing: 8) {
                if let text = AlertText.cleaned(alert.text) {
                    Text(text)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let datesText = Self.incidentDatesText(for: alert) {
                    Text(datesText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Button {
                    AppRouter.shared.selectedTab = .alerts
                    selectedIncidentAlertID = nil
                } label: {
                    Text("Veure a Avisos")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(Color.white.opacity(0.14), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Begin, end or the range between them, whichever the feed provides —
    /// the rule the former incident sheet rendered, reworded for the map card.
    private static func incidentDatesText(for alert: ServiceAlert) -> String? {
        switch (alert.beginDate, alert.endDate) {
        case let (begin?, end?):
            return "Del \(dayText(begin)) al \(dayText(end))"
        case let (begin?, nil):
            return "Des del \(dayText(begin))"
        case let (nil, end?):
            return "Fins al \(dayText(end))"
        case (nil, nil):
            return nil
        }
    }

    private static func dayText(_ date: Date) -> String {
        // The format the former incident sheet printed, as plain text.
        Self.alertDayFormatter.string(from: date)
    }

    /// An alert's calendar day, "12/03/2026". Pinned to a fixed locale and the
    /// Gregorian calendar, the convention `ScheduleTimetable` already follows:
    /// inheriting the device's would print a Thai Buddhist (2569), Japanese or
    /// Republic-of-China year instead of the one the feed means (#54).
    ///
    /// Internal so a test can pin the calendar and the locale: the rendered
    /// string alone cannot show them on a Gregorian device.
    static let alertDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "dd/MM/yyyy"
        return formatter
    }()

    // MARK: - Follow (S10)

    /// Re-center on the followed train if it is still on the line (spec S10).
    /// The span is kept as it is so following never zooms.
    ///
    /// The train sheet covers the bottom of the map while the follow is on, so
    /// the centre moves south by half of the covered height: the train lands in
    /// the middle of the band the sheet leaves visible instead of under the
    /// sheet's top edge. The anchor is the shifted centre, because that is the
    /// camera the command produces; anchoring the train itself would read as a
    /// rider pan by the tolerance check and release the follow.
    private func followTrain(in positions: [TrainPosition]) {
        guard let id = followingTrainID,
              let train = positions.first(where: { $0.id == id }) else { return }
        let offset = cameraSpan.latitudeDelta * Self.vehicleSheetCoverFraction / 2
        let center = CLLocationCoordinate2D(
            latitude: train.position.latitude - offset,
            longitude: train.position.longitude
        )
        followAnchor = GeoPoint(latitude: center.latitude, longitude: center.longitude)
        cameraPosition = .region(MKCoordinateRegion(center: center, span: cameraSpan))
    }

    /// Floor of the pan-detection tolerance, in degrees: below it our own
    /// 10 Hz follow commands would read as the rider moving the map (S10).
    private static let followPanToleranceDegrees = 0.002

    /// Fraction of the map height the train sheet covers at its compact detent,
    /// the first one it is presented with. The follow camera shifts its centre
    /// by half of it so the followed train stays in the visible band.
    private static let vehicleSheetCoverFraction = 0.35

    // MARK: - Router focus (S11)

    /// Act on a metro `.place`, `.line` or `.vehicle` focus (spec S11). The
    /// router already wrote `metroSelectedLine` for `.line` and `.vehicle`,
    /// and `@AppStorage` carries that into `selectedLineCode`; a `.place`
    /// picks one of the station's own lines.
    private func handlePendingFocus() {
        guard let focus = router.pendingFocus, focus.operator == AppModeCode.metro else { return }
        switch focus {
        case .line(_, let code):
            if let line = Self.metroLine(matching: code) {
                selectedLineCode = line.code
            }
            router.clearFocus()
        case .place(let place):
            guard place.kind == .metroStation else {
                router.clearFocus()
                return
            }
            // Close anything the previous subject left open, then follow the
            // station: the line change reloads the state, and the station
            // centering resolves with its topology (fitCamera path).
            selectedIncidentAlertID = nil
            // #31: a station focus is a new subject even when the station
            // belongs to the line already selected, where the `else` branch
            // below changes no line and the line-change handler never runs.
            // The train sheet and the follow would otherwise stay armed: the
            // follow re-centers on every position tick and overrides the
            // station centering, and the station sheet stays hidden behind
            // the train's subject.
            selectedTrain = nil
            followingTrainID = nil
            selectedVehicleID = nil
            if let line = place.lineCodes.first.flatMap(Self.metroLine(matching:)), line.code != selectedLineCode {
                pendingPlace = place
                selectedLineCode = line.code
                router.clearFocus()
            } else {
                pendingPlace = place
                router.clearFocus()
                resolvePendingPlace(in: lineState?.stations ?? [])
            }
        case .vehicle(_, let lineCode, let vehicleID):
            pendingVehicleID = vehicleID
            router.clearFocus()
            if let line = Self.metroLine(matching: lineCode), line.code != selectedLineCode {
                selectedLineCode = line.code
            } else {
                resolvePendingVehicleIfNeeded(in: lineState?.positions ?? [])
            }
        }
    }

    /// Metro line for a map code ("1") or a display name ("L1"): the two
    /// spellings `AppRouter` accepts (T1 convention).
    private static func metroLine(matching code: String) -> MetroLine? {
        MetroLine.allLines.first {
            $0.code == code || $0.displayName.caseInsensitiveCompare(code) == .orderedSame
        }
    }

    /// Resolve a `.place` focus once its station is on the map: center on it
    /// and open the existing station sheet (spec S11). A place that never
    /// shows up on the line it names is dropped so the camera goes back to
    /// fitting the line.
    private func resolvePendingPlace(in stations: [Station]) {
        guard let place = pendingPlace else { return }
        guard let station = Self.matchStation(for: place, in: stations) else {
            if !stations.isEmpty {
                pendingPlace = nil
                fitCamera(to: stations)
            }
            return
        }
        pendingPlace = nil
        selectedStation = station
        centerOn(station: station)
    }

    /// Station a metro `Place` refers to: the feed's `CODI_ESTACIO` or the
    /// catalog's `ID_ESTACIO`, then the folded name as the last resort.
    private static func matchStation(for place: Place, in stations: [Station]) -> Station? {
        if let code = Int(place.code) {
            if let byID = stations.first(where: { $0.id == code }) { return byID }
            if let byCode = stations.first(where: { $0.code == code }) { return byCode }
        }
        return stations.first { normalizedName($0.name) == normalizedName(place.name) }
    }

    private static func normalizedName(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "ca_ES"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Center on one station at street scale without touching the rest of the
    /// camera state (spec S11).
    private func centerOn(station: Station) {
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: station.latitude, longitude: station.longitude),
            span: MKCoordinateSpan(
                latitudeDelta: Self.placeFocusSpanDegrees,
                longitudeDelta: Self.placeFocusSpanDegrees
            )
        )
        cameraSpan = region.span
        withAnimation(AppMotion.smooth(duration: 0.35, reduceMotion: reduceMotion)) {
            cameraPosition = .region(region)
        }
    }

    /// Visible latitude span a focused station is shown at (S11).
    private static let placeFocusSpanDegrees = 0.02

    /// Resolve a `.vehicle` focus once its train is in the feed: open its
    /// sheet and turn the follow on (spec S11). A loaded line that does not
    /// carry the train means it left the network, so the focus is dropped.
    private func resolvePendingVehicleIfNeeded(in positions: [TrainPosition]) {
        guard let id = pendingVehicleID else { return }
        guard let train = positions.first(where: { $0.id == id }) else {
            if !positions.isEmpty { pendingVehicleID = nil }
            return
        }
        pendingVehicleID = nil
        // #31, mirror case: the train focus replaces the station sheet
        // instead of arming a second subject behind it, which used to appear
        // the moment the station sheet was dismissed.
        selectedStation = nil
        followingTrainID = id
        selectedTrain = train
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

    /// The line a train marker belongs to: the code of the position itself,
    /// falling back to the line on screen when the feed reports an unknown one.
    private func trainLine(for position: TrainPosition) -> MetroLine {
        MetroLine.line(forCode: position.lineCode) ?? selectedLine
    }

    /// Codes of the two end stations of the shown line, which get the slightly
    /// bigger hollow dot (S4).
    private static func terminalStationCodes(in stations: [Station]) -> Set<Int> {
        guard let first = stations.min(by: { $0.orderInLine < $1.orderInLine }),
              let last = stations.max(by: { $0.orderInLine < $1.orderInLine }) else { return [] }
        return [first.code, last.code]
    }
}

/// Inputs of the metro screen's load/poll task (spec S13): the line on screen
/// and whether metro is the visible mode. Changing either restarts the task, so
/// a mode switch cancels the poll of the screen being left and starts the one
/// of the screen entering.
private struct MetroLoadKey: Equatable {
    let isActive: Bool
    let lineCode: String
}

/// What the metro map draws that only depends on the line's topology and the
/// alerts feed (spec S8): the line polyline, the terminal dots, the incident
/// runs with their badges, the facility marks and the interchange capsules,
/// all ready for `MapContent`.
///
/// The 10 Hz position tick re-evaluates `body` but never rebuilds this value,
/// so grouping the incidents and mapping every polyline to map coordinates
/// happen off the render path.
private struct MetroMapOverlay {
    /// Coordinates of the line's polyline; empty until the geometry loads.
    var line: [CLLocationCoordinate2D] = []
    /// Codes of the two end stations of the line, which get the slightly
    /// bigger hollow dot (S4).
    var terminalCodes: Set<Int> = []
    /// Runs of consecutive affected stations, with the coordinates of each
    /// dotted overlay already mapped (spec S7).
    var incidentRuns: [IncidentRunLayer] = []
    /// One badge per run, at its middle station (spec S7).
    var incidentBadges: [IncidentRunBadge] = []
    /// Stations with a facility alert out of service (spec S7).
    var facilityStations: [FacilityStationMark] = []
    /// Display names of the other metro lines serving each station (D4),
    /// from the places catalog; the reader draws a capsule for a non-empty
    /// entry.
    var interchangeLineCodes: [Int: [String]] = [:]
}

/// One run of affected stations of the metro map with the coordinates of its
/// overlay (spec S7).
private struct IncidentRunLayer: Identifiable {
    let run: IncidentRun
    /// Coordinates of the dotted overlay; empty when the run has nothing to
    /// draw, which is the case the map skips.
    let coordinates: [CLLocationCoordinate2D]

    /// Identity of the run it draws, so the overlay survives a re-derivation.
    var id: Int { run.id }
}

/// Small station dot of the zoomed-out band (issue #93): the same 10 pt ring
/// the global map's `StationDot` draws — filled with the line colour, white
/// stroke — with no capsule and no name. The 44 pt frame is the touch target.
private struct ZoomedOutStationDot: View {
    let colorHex: String

    var body: some View {
        Circle()
            .fill(Color(hex: colorHex))
            .frame(width: 10, height: 10)
            .overlay(Circle().stroke(.white, lineWidth: 1.5))
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }
}

/// Hollow station dot on the map (spec S6, mockup `V3Markers`): white with a
/// stroke in the line colour, sitting on the track. A terminal is slightly
/// bigger. The 44 pt frame around the dot is the touch target.
private struct HollowStationDot: View {
    let colorHex: String
    let isTerminal: Bool

    var body: some View {
        Circle()
            .fill(Color.white)
            .frame(width: size, height: size)
            .overlay(Circle().stroke(Color(hex: colorHex), lineWidth: 3))
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }

    /// Mockup: radius 5.5 with a 3 pt stroke on a station, 6.5 on a terminal.
    private var size: CGFloat { isTerminal ? 16 : 14 }
}

/// White capsule of a metro–metro interchange (D4, mockup `V3Markers`): 20 pt
/// wide and 26 pt tall, filled white with a dark stroke.
private struct InterchangeCapsule: View {
    var body: some View {
        Capsule()
            .fill(Color.white)
            .frame(width: 20, height: 26)
            .overlay(Capsule().stroke(Color(hex: "1C1C1E"), lineWidth: 2.5))
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }
}
