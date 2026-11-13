import CoreLocation
import MapKit
import SwiftUI
import UIKit

/// Live map of one bus line (spec S3): the route of both directions in the
/// line color, the stops of the direction on screen as hollow dots, and the
/// buses placed from the arrivals the poll collected (spec S4, unified
/// markers of spec S6).
///
/// Affected runs draw dotted in the line's own colour with ONE amber badge per
/// run, and facility alerts show a small grey icon next to the stop (spec S7);
/// tapping a bus selects its glass card, and the bus sheet with the follow
/// mechanics stays for the router's focus intents (spec S10, S11).
///
/// It mirrors `MapScreen` on purpose — same chrome, same camera bookkeeping —
/// so switching mode changes the data and never the layout.
@MainActor
struct BusMapScreen: View {
    /// Whether bus is the mode on screen (spec S13). `RootView` keeps all four
    /// map screens mounted (spec S12), so this flag — and not the view's
    /// lifecycle — is what says whether the screen may load and poll: an
    /// off-screen mode does neither, and coming back resumes on the retained
    /// `BusLineState` without fetching its topology again.
    let isActive: Bool
    /// Hook for the nearby sheet (spec S13, T5): called after the location
    /// button centers the camera on the rider. Defaults to nothing.
    var onLocate: (() -> Void)? = nil
    @EnvironmentObject private var app: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Catalog and picker state, shared with the bus Línies screen so both
    /// always show the same line (spec S2). Read as a plain property: the
    /// `@Observable` store registers the view on its own when the body reads
    /// it, so there is no second copy of the catalog to keep in sync.
    private var store: BusCatalogStore { BusCatalogStore.shared }
    @State private var lineState: BusLineState?
    /// What the map draws that does not depend on the 10 Hz position tick: the
    /// route coordinates of both directions and the stops with an incident
    /// (spec S8). Re-derived from the topology, the direction chip and the
    /// alerts feed, never while `body` runs.
    @State private var mapOverlay = BusMapOverlay()
    /// `ID_SENTIT` of the direction on screen, shared with the bottom
    /// accessory through `BusDirectionSelection`'s storage key (spec S4): the
    /// accessory's swap button writes it, and this screen resolves it against
    /// the line's directions the same way. Full opacity for its route and its
    /// stops, dimmed for the other one (spec S3).
    @AppStorage(BusDirectionSelection.storageKey) private var storedDirectionID = 1
    /// Stop whose sheet is open (spec S6).
    @State private var selectedStop: BusStop?
    /// Vehicle the rider selected by tapping its marker (spec S6): tapping
    /// again, closing the card or changing the line deselects it. A user
    /// action, so it may re-diff; nothing on the 10 Hz position path touches
    /// it.
    @State private var selectedVehicleID: String?
    /// Alert id whose service card is open through its run's badge (spec S7).
    @State private var selectedIncidentAlertID: String?
    /// Bus whose sheet is open (spec S10). A snapshot copy: the sheet reads
    /// the live position from the line's state by id.
    @State private var selectedBus: BusPosition?
    /// Bus the camera is following, or nil (spec S10).
    @State private var followingVehicleID: String?
    /// Where the camera was commanded to last, so the continuous callback can
    /// tell our own follow animation from a pan by the rider — the FGC map's
    /// pattern (spec S10).
    @State private var followAnchor: GeoPoint?
    /// Span the camera follows with: kept current by every camera change so
    /// re-centering never zooms (spec S10).
    @State private var cameraSpan = MapScreen.barcelonaRegion.span
    /// Router focus intents waiting for their data (spec S11): the place whose
    /// sheet cannot open before its line's topology has loaded, and the
    /// vehicle id that is not in the feed yet.
    @State private var pendingPlaceFocus: Place?
    @State private var pendingVehicleFocusID: String?
    /// Latitude span on screen, which decides whether the stop dots of the
    /// direction on screen are drawn at all (spec S3).
    @State private var latitudeSpan: Double = BusMapScreen.initialRegion.span.latitudeDelta
    // Named type instead of `Self` on purpose: a stored-property initializer has
    // no instance context, so the spelled-out type name is the form that is
    // guaranteed to compile.
    @State private var cameraPosition: MapCameraPosition = .region(BusMapScreen.initialRegion)

    /// App-wide navigation intent (spec S11): bus focuses are handled here and
    /// cleared by this screen.
    private var router: AppRouter { AppRouter.shared }
    /// Device location for the blue dot (spec S11).
    private var location: LocationService { LocationService.shared }
    /// Whether the map may draw the rider's position at all. A denied or
    /// restricted permission simply leaves the dot and the button away (S11).
    private var isLocationAuthorized: Bool {
        location.authorization == .authorizedWhenInUse || location.authorization == .authorizedAlways
    }

    /// Whether the location permission has not been decided yet: the location
    /// button then asks for it instead of centering (spec S11, S3).
    private var isLocationNotDetermined: Bool {
        location.authorization == .notDetermined
    }

    /// Whether the device currently has a network path (spec S2): when it
    /// does not, the status capsule shows the offline wording even before the
    /// first poll answers.
    private var isOnline: Bool {
        ConnectivityMonitor.shared.isOnline
    }

    var body: some View {
        NavigationStack {
            ZStack {
                mapArea
                    // The placeholder and the map swap with a short fade when
                    // the line's state first arrives (polish pass).
                    .animation(AppMotion.smooth(reduceMotion: reduceMotion), value: lineState != nil)
            }
            // Spec S1: no header — the mode selector, the line button, the
            // direction picker and the counts move to the bottom accessory,
            // the map fills the screen under the status bar, and the v2
            // chrome lives in overlays (spec S1).
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
                if let state = lineState, state.hasNoBuses {
                    // Below the capsule instead of colliding with it (spec S1).
                    NoBusesCard()
                        .padding(.horizontal, 16)
                        .padding(.top, 52)
                        .transition(AppMotion.chipTransition)
                }
            }
            // The capsule joins the chrome the moment the line's state exists:
            // fade and shrink it in instead of a pop (polish pass).
            .animation(AppMotion.smooth(reduceMotion: reduceMotion), value: lineState != nil)
            // Changing the bus line is a selection, so it clicks (polish pass).
            .sensoryFeedback(.selection, trigger: store.selectedLine?.code)
            // Both loader tasks live on the always-visible container: the map
            // only renders once a line is selected and its state exists, so a
            // task attached there would never start.
            //
            // Spec S13: neither runs while the bus mode is off screen. The
            // catalog load the screen left behind is a no-op on resume (it
            // guards on an already loaded catalog), so only the poll restarts.
            .task(id: isActive) {
                guard isActive else { return }
                guard let client = app.client else { return }
                await store.load(client: client)
            }
            // Keyed on the resolved line, not the stored code: `selectedLineCode`
            // is restored from UserDefaults before the catalog loads, so the task
            // would exit through the guard and never re-run when the line arrives.
            .task(id: BusLoadKey(isActive: isActive, lineCode: store.selectedLine?.code)) {
                guard isActive else { return }
                guard let client = app.client, let line = store.selectedLine else { return }
                // Spec S13: the state survives the mode switch, so returning to
                // the bus mode resumes its poll instead of loading the line
                // again. A different line is a different state, as before.
                if let retained = lineState, retained.line.code == line.code {
                    await retained.run()
                    return
                }
                let state = BusLineState(line: line, client: client)
                self.lineState = state
                // A new line is a new overlay: clearing it here also keeps one
                // line's routes from being drawn over another's while the two
                // publish the same `ID_SENTIT` values (spec S8).
                refreshMapOverlay()
                await state.run()
            }
            // Focus intents from the router (spec S11): applied when they
            // arrive and on appear, when the screen may have been created by
            // the mode switch itself.
            .onAppear {
                applyFocus(router.pendingFocus)
                resolvePendingFocuses()
            }
            .onChange(of: router.pendingFocus) { _, destination in
                applyFocus(destination)
            }
            // Catalog arrival: a pending place focus that could not name a
            // line yet can pick one of the stop's lines now.
            .onChange(of: store.lines.count) { _, _ in
                resolvePendingFocuses()
            }
            .onChange(of: store.selectedLine?.code) { _, _ in
                // A new line is a new subject: drop the old bus, its follow,
                // the vehicle selection, any incident card (S10, S6, S7) and
                // the stop sheet, which titles and colours itself with the
                // current line and derives its incidents from it (bug #53).
                // A pending place focus reopens the stop it names below.
                selectedStop = nil
                selectedBus = nil
                followingVehicleID = nil
                selectedVehicleID = nil
                selectedIncidentAlertID = nil
                resolvePendingFocuses()
            }
            // The selected subject's glass card sits above the tab bar and the
            // accessory, inside the safe area (spec S6, S7, mockup `V3Bus`).
            // One card at a time: the incident badge and the vehicle marker
            // deselect each other.
            .overlay(alignment: .bottom) {
                if let alertID = selectedIncidentAlertID,
                   let alert = app.busAlerts.first(where: { $0.id == alertID }),
                   let state = lineState {
                    incidentCard(for: alert, line: state.line)
                } else if let vehicleID = selectedVehicleID, let state = lineState,
                          let position = state.positions.first(where: { $0.id == vehicleID }) {
                    vehicleCard(for: position, state: state, line: state.line)
                }
            }
            .onChange(of: lineState?.directions.map(\.id)) { _, _ in
                // Topology of the (new) line arrived: place focuses waiting
                // for it can open their sheet now (spec S11), and the map
                // overlay (routes and incident stops) can be derived from it
                // once instead of on every render (spec S8).
                refreshMapOverlay()
                resolvePendingFocuses()
            }
            // The (shared) direction changes which route is drawn at full
            // colour and whose stops carry the incident markers, so the
            // overlay is re-derived on the change (spec S8, S4).
            .onChange(of: storedDirectionID) { _, _ in
                refreshMapOverlay()
            }
            // A new bus alerts feed re-derives the incident stops (spec S8).
            .onChange(of: app.busAlertsUpdatedAt) { _, _ in
                refreshMapOverlay()
            }
            // Spec S1: the map screens show no navigation bar.
            .toolbar(.hidden, for: .navigationBar)
        }
        // Declared on the stack itself, like the metro station sheet: presented
        // from a view nested in the stack its first rows end up under the
        // navigation bar.
        .sheet(item: $selectedStop) { stop in
            if let line = store.selectedLine, let state = lineState {
                BusStopSheet(
                    stop: stop,
                    line: line,
                    incidents: incidents(for: stop, in: state, line: line),
                    delays: delays(for: stop, in: state)
                )
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
        // The bus sheet of spec S10. Closing it releases the camera, like the
        // FGC train sheet does. The compact first detent fits the sheet's
        // content — badge, destination, next stop and "Seguir" — without
        // scrolling; `.medium` and `.large` stay for the rest.
        .sheet(item: $selectedBus, onDismiss: { followingVehicleID = nil }) { bus in
            if let state = lineState {
                BusVehicleSheet(
                    state: state,
                    positionID: bus.id,
                    allowFollow: true,
                    followingVehicleID: $followingVehicleID
                )
                    .presentationDetents([.fraction(0.35), .medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    // MARK: - The v2 chrome (spec S1)

    /// The status capsule over the map (spec S2): freshness of the bus poll
    /// and connectivity in one glass capsule. Online it waits for the line's
    /// state, as the old chip row did; offline it is always there, because the
    /// saved-data wording is what the map needs before the first poll answers.
    @ViewBuilder
    private var statusCapsule: some View {
        if let state = lineState {
            FreshnessChip(
                updatedAt: state.arrivalsUpdatedAt,
                lastAttemptFailed: state.lastPollFailed,
                feedEmpty: state.hasNoBuses
            )
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

    /// The direction the shared storage resolves to, against the line's
    /// directions: nil until the topology has arrived (spec S4).
    private func resolvedDirectionID(in state: BusLineState) -> Int? {
        BusDirectionSelection.resolve(stored: storedDirectionID, available: state.directions.map(\.id))
    }

    // MARK: - Map

    @ViewBuilder
    private var mapArea: some View {
        if let message = app.missingCredentialsMessage {
            ConfigurationNotice(message: message)
        } else if let line = store.selectedLine, let state = lineState {
            lineMap(state: state, line: line)
                .transition(.opacity)
        } else if let message = store.errorMessage {
            // The catalog sheet reached from the line selector offers the
            // retry; here the reason is only stated.
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            MapLoadingPlaceholder()
                .transition(.opacity)
        }
    }

    @ViewBuilder
    private func lineMap(state: BusLineState, line: BusLine) -> some View {
        // The routes and the incident runs come from `mapOverlay`, derived
        // when the topology, the direction chip or the alerts changed
        // (spec S8): neither the grouping of the incidents nor the
        // `GeoPoint` → `CLLocationCoordinate2D` mapping of a route happens on
        // the render path.
        Map(position: $cameraPosition) {
            if isLocationAuthorized {
                // The rider's own dot (spec S11). Unauthorized, it is simply
                // not drawn; a denied permission never blocks the map.
                UserAnnotation()
            }
            ForEach(state.directions) { direction in
                // One polyline per direction: the selected one at full color,
                // the other at 40 % (spec S3). The opacity goes into the stroke
                // color because a map overlay has no view opacity to set.
                let coordinates = mapOverlay.routeCoordinates[direction.id] ?? []
                if coordinates.count >= 2 {
                    let shown = resolvedDirectionID(in: state)
                    MapPolyline(coordinates: coordinates)
                        .stroke(
                            Color(hex: line.colorHex).opacity(direction.id == shown ? 1 : 0.4),
                            style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round)
                        )
                }
            }
            if let direction = shownDirection(in: state), latitudeSpan < Self.stopSpanThreshold {
                ForEach(direction.stops) { stop in
                    // Empty title: the stop name belongs to the sheet it opens.
                    Annotation("", coordinate: CLLocationCoordinate2D(latitude: stop.latitude, longitude: stop.longitude)) {
                        Button {
                            selectedStop = stop
                        } label: {
                            HollowStopDot(colorHex: line.colorHex)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Parada \(stop.name)")
                    }
                }
            }
            // Each run of consecutively affected stops overlays the shown
            // direction's route with a dotted line in the line's own colour —
            // never red, the colour stays the line's (spec S7, mockup
            // `V3Markers`). Not zoom-gated: an incident is worth seeing from
            // the whole-line view down.
            ForEach(mapOverlay.incidentRuns) { incidentRun in
                if incidentRun.coordinates.count >= 2 {
                    MapPolyline(coordinates: incidentRun.coordinates)
                        .stroke(
                            Color(hex: line.colorHex).opacity(0.9),
                            style: StrokeStyle(lineWidth: 5, lineCap: .round, dash: [0.1, 9])
                        )
                }
            }
            // ONE amber badge per affected run, at the run's middle stop (spec
            // S7, mockup `V3Bus`).
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
            // Small grey icon next to every stop with a facility alert out of
            // service, slightly offset so the stop dot stays visible (spec S7).
            ForEach(mapOverlay.facilityStops) { mark in
                Annotation("", coordinate: CLLocationCoordinate2D(latitude: mark.latitude, longitude: mark.longitude)) {
                    FacilityStationIcon(kind: mark.kind)
                        .offset(x: 12, y: -12)
                        .accessibilityLabel(facilityAccessibilityText(mark, state: state))
                }
            }
            ForEach(state.positions) { position in
                // Empty title: the marker speaks for itself and the selected
                // vehicle's glass card carries the destination (spec S6). D5:
                // every bus position is arrival-based, so the marker keeps a
                // solid ring and the card says where the estimate comes from.
                Annotation("", coordinate: CLLocationCoordinate2D(latitude: position.train.position.latitude, longitude: position.train.position.longitude)) {
                    Button {
                        // Tapping selects the vehicle and closes any incident
                        // card; tapping again deselects (spec S6). The bus
                        // sheet stays for `AppRouter` `.vehicle` focuses.
                        selectedIncidentAlertID = nil
                        selectedVehicleID = selectedVehicleID == position.id ? nil : position.id
                    } label: {
                        vehicleMarker(for: position, line: line)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Bus de la línia \(line.name) cap a \(position.train.destination)")
                }
            }
        }
        .mapStyle(.standard(elevation: .flat))
        // Spec S1: the map fills the screen under the status bar; the chrome
        // overlays above keep their safe-area insets.
        .ignoresSafeArea(.container, edges: .top)
        // Pan detection for the follow (spec S10), the FGC map's rule: a
        // change whose center is not near the point we last commanded is the
        // rider moving the map, so the camera releases the bus. Zoom keeps it.
        .onMapCameraChange(frequency: .continuous) { context in
            latitudeSpan = context.region.span.latitudeDelta
            cameraSpan = context.region.span
            guard followingVehicleID != nil, let anchor = followAnchor else { return }
            let tolerance = max(Self.followPanToleranceDegrees, cameraSpan.latitudeDelta * 0.05)
            let center = context.region.center
            if abs(center.latitude - anchor.latitude) > tolerance
                || abs(center.longitude - anchor.longitude) > tolerance {
                followingVehicleID = nil
            }
        }
        // The 10 Hz ticker updates `positions`: while a bus is followed, the
        // camera re-centers on it, keeping the span (spec S10). A vehicle
        // focus waiting for its bus to appear in the feed is checked here too.
        .onChange(of: state.positions.map(\.train)) { _, _ in
            followBus(in: state)
            resolvePendingVehicleFocus()
        }
        .overlay {
            if state.isLoading {
                ProgressView()
                    .padding(12)
                    .background(.thinMaterial, in: Circle())
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
        .onChange(of: state.directions.map(\.id)) { _, ids in
            // The shared storage resolves against the new directions (spec
            // S4), so the clamp the old local `@State` needed is gone.
            // Fitted whenever the directions first become non-empty, which
            // covers both the first load and a change of line — but never
            // over a focus intent, whose centering would be erased (S11).
            if !state.directions.isEmpty, pendingPlaceFocus == nil, pendingVehicleFocusID == nil {
                fitCamera(to: state)
            }
        }
        .onAppear {
            // A direction set that was already loaded (a focus that switched
            // the line before the map appeared) needs its overlay too (S8).
            refreshMapOverlay()
            if !state.directions.isEmpty, pendingPlaceFocus == nil, pendingVehicleFocusID == nil {
                fitCamera(to: state)
            }
        }
        // No content-keyed `.animation` on the direction set: it animated the
        // whole annotation set on a line switch, which read as a doubled
        // annotation layer (map-perf S14b). Annotations pop in like the FGC
        // map already does; the placeholder fade (`lineState != nil`) stays.
    }

    /// The direction the shared storage selects, falling back to the first one
    /// of the line so a line that only publishes one direction still draws its
    /// stops (spec S4).
    private func shownDirection(in state: BusLineState) -> BusDirection? {
        let resolved = resolvedDirectionID(in: state)
        return state.directions.first { $0.id == resolved } ?? state.directions.first
    }

    // MARK: - Selected subject cards (S6, S7)

    /// The marker of one bus (spec S6, mockup `V3Markers`): the unified marker
    /// in the line's colour with the heading wedge, upright and ring solid
    /// (D5); the selected bus gets the halo plus a small glass label with its
    /// destination under the marker. The overlay adds nothing to the layout
    /// frame, so MapKit keeps centering the annotation on the coordinate.
    private func vehicleMarker(for position: BusPosition, line: BusLine) -> some View {
        VehicleMarkerView(
            colorHex: line.colorHex,
            glyph: .bus,
            headingDegrees: position.train.heading,
            isEstimated: false,
            isSelected: selectedVehicleID == position.id
        )
        .overlay(alignment: .bottom) {
            if selectedVehicleID == position.id {
                Text(position.train.destination)
                    .font(.caption2.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .glassEffect(in: Capsule())
                    .fixedSize()
                    .offset(y: 22)
            }
        }
    }

    /// Glass card of the selected bus (spec S6, mockup `V3Bus`): the line
    /// badge, the head-sign destination, the next stop with its countdown
    /// when the data exists (never a new request: the row reads the same
    /// positions and arrivals the screen already holds), and where the
    /// estimate comes from (D5).
    private func vehicleCard(for position: BusPosition, state: BusLineState, line: BusLine) -> some View {
        MapGlassCard(
            badgeText: line.name,
            badgeColorHex: line.colorHex,
            title: position.train.destination.isEmpty
                ? String(localized: "Destí desconegut")
                : String(localized: "Cap a \(position.train.destination)"),
            onClose: { selectedVehicleID = nil }
        ) {
            VStack(alignment: .leading, spacing: 8) {
                if let stopName = nextStopName(for: position, in: state) {
                    Text("Pròxima: \(stopName) · \(Arrival.countdownText(seconds: position.train.secondsToArrival))")
                        .font(.subheadline.weight(.medium))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(
                            "Pròxima \(stopName), arriba en \(Arrival.countdownText(seconds: position.train.secondsToArrival))"
                        )
                }
                VehiclePositionSource(
                    isEstimated: true,
                    estimatedText: String(localized: "Posició estimada a partir de les arribades (iBus)")
                )
                // The existing bus sheet: next stops and "follow" stay
                // reachable from a plain tap.
                Button {
                    selectedBus = position
                } label: {
                    Label("Més detalls", systemImage: "info.circle")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    /// Name of the stop the bus is approaching: `nextStationCode` is a bus
    /// stop code here, resolved against the bus's own direction first, the
    /// same rule `BusVehicleSheet` applies. Nil when neither can name it.
    private func nextStopName(for position: BusPosition, in state: BusLineState) -> String? {
        let code = position.train.nextStationCode
        if let direction = state.directions.first(where: { $0.id == position.directionID }),
           let stop = direction.stops.first(where: { $0.code == code }) {
            return stop.name
        }
        if let stop = state.directions.flatMap(\.stops).first(where: { $0.code == code }) {
            return stop.name
        }
        return nil
    }

    /// #99: VoiceOver names where the mark is — the stop it sits next to
    /// — not the stop code the mark carries. Falls back to no stop name when
    /// the line state no longer lists that code.
    private func facilityAccessibilityText(
        _ mark: FacilityStationMark,
        state: BusLineState
    ) -> String {
        if let name = state.directions.flatMap(\.stops)
            .first(where: { $0.code == mark.stationCode })?.name {
            return String(localized: "Incidència d'instal·lació a la parada \(name)")
        }
        return String(localized: "Incidència d'instal·lació en una parada")
    }

    /// Glass card of a run's amber badge (spec S7): the alert's text and time
    /// and a jump to the Avisos tab. The badge's text already carries the
    /// line, so the card repeats it as its badge.
    private func incidentCard(for alert: ServiceAlert, line: BusLine) -> some View {
        MapGlassCard(
            badgeText: line.name,
            badgeColorHex: line.colorHex,
            title: String(localized: "Servei afectat"),
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
            return String(localized: "Del \(dayText(begin)) al \(dayText(end))")
        case let (begin?, nil):
            return String(localized: "Des del \(dayText(begin))")
        case let (nil, end?):
            return String(localized: "Fins al \(dayText(end))")
        case (nil, nil):
            return nil
        }
    }

    private static func dayText(_ date: Date) -> String {
        // The format the former incident sheet printed, as plain text.
        MapScreen.alertDayFormatter.string(from: date)
    }

    // No formatter of its own (#80): the bus card prints the same "dd/MM/yyyy"
    // Gregorian day the metro map's pinned formatter renders.

    /// Incidents of one stop from the bus alerts feed (spec S7). Both
    /// directions are mapped to `Station` values because the same physical stop
    /// appears once per direction.
    private func incidents(for stop: BusStop, in state: BusLineState, line: BusLine) -> [StationIncident] {
        let code = String(line.code)
        let stations = state.directions.flatMap(\.stops).map { $0.asStation(lineCode: code) }
        return IncidentIndex.incidents(
            for: app.activeBusAlerts(affecting: code),
            stations: stations,
            lineCode: code
        )[stop.code] ?? []
    }

    /// Runs of consecutively affected stops of the direction on screen, one
    /// amber badge per run, and the stops carrying a facility icon (spec S7),
    /// from an `IncidentIndex` pass over the same `AppModel.busAlerts` source
    /// `BusStopSheet` reads. Only the direction on screen derives them: the
    /// direction chip re-triggers the derivation, and the same physical stop
    /// appears in both directions with the same code.
    ///
    /// Static and takes its inputs explicitly because the map derives it when
    /// the directions, the direction chip or the alerts change, never from the
    /// 10 Hz render path (spec S8).
    private static func incidentPresentation(
        direction: BusDirection,
        line: BusLine,
        alerts: [ServiceAlert]
    ) -> (
        runs: [BusIncidentRunLayer],
        badges: [IncidentRunBadge],
        facilityStops: [FacilityStationMark]
    ) {
        guard !alerts.isEmpty else { return ([], [], []) }
        let code = String(line.code)
        let stops = direction.stops.map { $0.asStation(lineCode: code) }
        let incidents = IncidentIndex.incidents(
            for: alerts,
            stations: stops,
            lineCode: code
        )
        var serviceIncidents: [Int: [StationIncident]] = [:]
        var facilityStops: [FacilityStationMark] = []
        for (stopCode, list) in incidents {
            let facilityList = list.filter { ParadesTimeline.isFacilityIncident($0) }
            let serviceList = list.filter { !ParadesTimeline.isFacilityIncident($0) }
            if !facilityList.isEmpty, let stop = direction.stops.first(where: { $0.code == stopCode }) {
                facilityStops.append(FacilityStationMark(
                    stationCode: stopCode,
                    kind: facilityList[0].kind,
                    latitude: stop.latitude,
                    longitude: stop.longitude
                ))
            }
            if !serviceList.isEmpty {
                serviceIncidents[stopCode] = serviceList
            }
        }
        var runs: [BusIncidentRunLayer] = []
        var badges: [IncidentRunBadge] = []
        for overlay in IncidentSegments.overlays(
            stations: stops,
            incidents: serviceIncidents,
            geometry: direction.route
        ) {
            if overlay.points.count >= 2 {
                runs.append(BusIncidentRunLayer(
                    run: overlay.run,
                    coordinates: overlay.points.map { point in
                        CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
                    }
                ))
            }
            if let badge = IncidentBadgePlacement.badge(
                for: overlay.run,
                lineDisplayName: line.name,
                serviceIncidents: serviceIncidents
            ) {
                badges.append(badge)
            }
        }
        return (runs, badges, facilityStops)
    }

    /// Re-derives the map overlay of the line on screen: the coordinates of
    /// both routes, the incident runs of the direction on screen with their
    /// badges, and the stops carrying a facility icon (spec S8). Called when
    /// the topology, the direction chip or the alerts feed changes.
    private func refreshMapOverlay() {
        guard let state = lineState else {
            mapOverlay = BusMapOverlay()
            return
        }
        var routes: [Int: [CLLocationCoordinate2D]] = [:]
        for direction in state.directions {
            routes[direction.id] = Self.mapCoordinates(of: direction.route.points)
        }
        var runs: [BusIncidentRunLayer] = []
        var badges: [IncidentRunBadge] = []
        var facilityStops: [FacilityStationMark] = []
        if let direction = shownDirection(in: state) {
            let presentation = Self.incidentPresentation(
                direction: direction,
                line: state.line,
                alerts: app.activeBusAlerts(affecting: String(state.line.code))
            )
            runs = presentation.runs
            badges = presentation.badges
            facilityStops = presentation.facilityStops
        }
        mapOverlay = BusMapOverlay(
            routeCoordinates: routes,
            incidentRuns: runs,
            incidentBadges: badges,
            facilityStops: facilityStops
        )
    }

    /// Map coordinates of a polyline (spec S8): the one place the `GeoPoint` →
    /// `CLLocationCoordinate2D` conversion happens, so it runs when a route
    /// changes and never on a position tick.
    private static func mapCoordinates(of points: [GeoPoint]) -> [CLLocationCoordinate2D] {
        points.map { point in
            CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
        }
    }

    /// The delay of each bus the sheet lists, estimated against the timetable
    /// (spec S7). The ids are the ones this stop's arrivals already name, so
    /// nothing is polled for the sheet: `delay(forBus:)` answers from the last
    /// poll. Lines the schedule cannot place simply have no entry.
    private func delays(for stop: BusStop, in state: BusLineState) -> [Int: DelayEstimate] {
        var estimates: [Int: DelayEstimate] = [:]
        for arrival in state.arrivalsByStop[stop.code] ?? [] {
            guard let busID = arrival.busID, let estimate = state.delay(forBus: busID) else { continue }
            estimates[busID] = estimate
        }
        return estimates
    }

    /// Fit the camera to the whole line on every change of line, so a long
    /// horizontal line is not cut off by the fixed Barcelona region.
    private func fitCamera(to state: BusLineState) {
        guard let region = Self.region(fitting: state.directions.flatMap { $0.route.points }) else { return }
        withAnimation(.easeInOut(duration: 0.35)) {
            cameraPosition = .region(region)
        }
    }

    // MARK: - Focus and follow (specs S10, S11)

    /// Applies a router focus addressed to the bus operator (spec S11).
    /// A focus for another operator is left untouched for its own map.
    private func applyFocus(_ destination: Destination?) {
        guard let destination, destination.operator == AppModeCode.bus else { return }
        switch destination {
        case .line(_, let code):
            _ = selectBusLine(byCode: code)
            router.clearFocus()
        case .place(let place):
            guard place.kind == .busStop else { return }
            pendingPlaceFocus = place
            resolvePendingPlaceFocus()
        case .vehicle(_, let lineCode, let vehicleID):
            pendingVehicleFocusID = vehicleID
            let changedLine = selectBusLine(byCode: lineCode)
            // With the same line on screen nothing will re-trigger the
            // resolution, so try now; a line change clears the old sheet
            // first, and the next data tick opens the new one.
            if !changedLine {
                resolvePendingVehicleFocus()
            }
            router.clearFocus()
        }
    }

    /// Points the catalog selection at the line a focus names: the numeric
    /// code, or a commercial name resolved through the loaded catalog
    /// (spec S11, and the selection API of `BusCatalogStore`).
    /// - Returns: whether the selection actually moved.
    @discardableResult
    private func selectBusLine(byCode code: String) -> Bool {
        let target: Int?
        if let numeric = Int(code) {
            target = numeric
        } else {
            target = store.lines.first { $0.name.caseInsensitiveCompare(code) == .orderedSame }?.code
        }
        guard let target, store.selectedLineCode != target else { return false }
        store.selectedLineCode = target
        return true
    }

    /// Re-runs every pending resolution. Idempotent: with no pending intent
    /// it does nothing, so every data-arrival trigger may call it.
    private func resolvePendingFocuses() {
        resolvePendingPlaceFocus()
        resolvePendingVehicleFocus()
    }

    /// Opens the sheet of a pending bus-stop focus once its line and its
    /// topology are on screen (spec S11).
    private func resolvePendingPlaceFocus() {
        guard let place = pendingPlaceFocus, place.kind == .busStop else { return }
        guard let stopCode = Int(place.code) else {
            finishPlaceFocus(centering: place)
            return
        }
        if store.selectedLine == nil {
            // Nothing on screen yet: take a line of the stop through the
            // catalog and wait for its state.
            _ = selectLineServing(place)
            return
        }
        // The mounted state must be the selected line's: the catalog selection
        // changes before the new line's state loads, so a resolution here
        // would look the stop up in the line being left and give up on it
        // (#76). The new state's directions change re-runs this.
        guard let state = lineState, !state.directions.isEmpty,
              state.line.code == store.selectedLine?.code else { return }
        if let stop = preferredStop(code: stopCode, in: state) {
            pendingPlaceFocus = nil
            selectedStop = stop
            centerCamera(on: GeoPoint(latitude: stop.latitude, longitude: stop.longitude))
            router.clearFocus()
            return
        }
        // The loaded line does not serve this stop: try one of the stop's
        // other lines once; with none left, centering is all there can be.
        if selectLineServing(place) { return }
        finishPlaceFocus(centering: place)
    }

    private func finishPlaceFocus(centering place: Place) {
        pendingPlaceFocus = nil
        centerCamera(on: place.position)
        router.clearFocus()
    }

    /// Selects a line of the stop that is not the one already on screen
    /// (spec S11). False when the catalog knows none.
    private func selectLineServing(_ place: Place) -> Bool {
        for name in place.lineCodes {
            guard let line = store.lines.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }),
                  line.code != store.selectedLineCode else { continue }
            store.selectedLineCode = line.code
            return true
        }
        return false
    }

    /// The stop entry to open for a stop code: the direction on screen first,
    /// so the sheet's line context matches what the rider is looking at.
    private func preferredStop(code: Int, in state: BusLineState) -> BusStop? {
        let matches = state.directions.flatMap(\.stops).filter { $0.code == code }
        if let shown = shownDirection(in: state),
           let stop = matches.first(where: { $0.directionID == shown.id }) {
            return stop
        }
        return matches.first
    }

    /// Opens the bus sheet with follow on once the focused vehicle exists in
    /// the feed (spec S11, S10).
    private func resolvePendingVehicleFocus() {
        // Same rule as the place focus (#76): resolve only against the state
        // of the line that is selected now.
        guard let vehicleID = pendingVehicleFocusID, let state = lineState,
              state.line.code == store.selectedLine?.code else { return }
        guard let position = state.positions.first(where: { $0.id == vehicleID || $0.train.id == vehicleID }) else {
            return
        }
        pendingVehicleFocusID = nil
        selectedBus = position
        followingVehicleID = position.id
        centerCamera(on: position.train.position)
    }

    /// Re-center on the followed bus if it is still in the feed (spec S10).
    /// The span is kept as it is so following never zooms — the FGC mechanic.
    ///
    /// The bus sheet covers the bottom of the map while the follow is on, so the
    /// centre moves south by half of the covered height and the bus lands in the
    /// middle of the band the sheet leaves visible. The anchor is the shifted
    /// centre the camera reports back; anchoring the bus itself would read as a
    /// rider pan and release the follow.
    private func followBus(in state: BusLineState) {
        guard let id = followingVehicleID,
              let position = state.positions.first(where: { $0.id == id }) else { return }
        let offset = cameraSpan.latitudeDelta * Self.vehicleSheetCoverFraction / 2
        let center = CLLocationCoordinate2D(
            latitude: position.train.position.latitude - offset,
            longitude: position.train.position.longitude
        )
        followAnchor = GeoPoint(latitude: center.latitude, longitude: center.longitude)
        cameraPosition = .region(MKCoordinateRegion(center: center, span: cameraSpan))
    }

    /// Zoom to a stop or a vehicle and re-center on it (spec S11).
    private func centerCamera(on point: GeoPoint) {
        let span = MKCoordinateSpan(
            latitudeDelta: Self.focusSpanDegrees,
            longitudeDelta: Self.focusSpanDegrees
        )
        cameraSpan = span
        withAnimation(AppMotion.smooth(reduceMotion: reduceMotion)) {
            cameraPosition = .region(
                MKCoordinateRegion(
                    center: CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude),
                    span: span
                )
            )
        }
    }

    /// Smallest span kept per axis, so a short line or a route whose points all
    /// sit on one place does not zoom the map to street level.
    private static let minSpanDegrees = 0.01

    /// Region that contains every route point, padded by 30 % per axis so the
    /// end stops do not touch the edge of the screen. Nil for an empty list.
    private static func region(fitting points: [GeoPoint]) -> MKCoordinateRegion? {
        guard let first = points.first else { return nil }
        var minLatitude = first.latitude
        var maxLatitude = first.latitude
        var minLongitude = first.longitude
        var maxLongitude = first.longitude
        for point in points {
            minLatitude = min(minLatitude, point.latitude)
            maxLatitude = max(maxLatitude, point.latitude)
            minLongitude = min(minLongitude, point.longitude)
            maxLongitude = max(maxLongitude, point.longitude)
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

    /// Region the map opens with, before the camera is fitted to the line: the
    /// same Barcelona frame the metro map uses.
    private static let initialRegion = MapScreen.barcelonaRegion

    /// Below this visible latitude span the stops of the direction on screen are
    /// drawn (spec S3).
    private static let stopSpanThreshold = 0.03

    /// Span a focus centers with: close enough for the stop sheet or the bus
    /// sheet to be about something on screen, under the stop-dot threshold so
    /// the neighborhood stays drawn (spec S11).
    private static let focusSpanDegrees = 0.01

    /// Floor of the pan-detection tolerance, in degrees: below it our own
    /// 10 Hz follow commands would read as the rider moving the map. The FGC
    /// map's constant, copied because both maps release the follow the same
    /// way (spec S10).
    private static let followPanToleranceDegrees = 0.002

    /// Fraction of the map height the bus sheet covers at its compact detent,
    /// the first one it is presented with. The follow camera shifts its centre
    /// by half of it so the followed bus stays in the visible band.
    private static let vehicleSheetCoverFraction = 0.35
}

/// Inputs of the bus screen's load/poll task (spec S13): the selected line and
/// whether bus is the visible mode. Changing either restarts the task, so a
/// mode switch cancels the poll of the screen being left and starts the one of
/// the screen entering.
private struct BusLoadKey: Equatable {
    let isActive: Bool
    let lineCode: Int?
}

/// What the bus map draws that only depends on the line's topology, the
/// direction chip and the alerts feed (spec S8): the polyline of each direction,
/// the incident runs of the direction on screen with their badges, and the
/// stops that carry a facility icon.
///
/// The 10 Hz position tick re-evaluates `body` but never rebuilds this value,
/// so neither the incident grouping nor the `GeoPoint` →
/// `CLLocationCoordinate2D` mapping of a route happens on the render path.
private struct BusMapOverlay {
    /// Coordinates of each direction's route, keyed by `ID_SENTIT`.
    var routeCoordinates: [Int: [CLLocationCoordinate2D]] = [:]
    /// Runs of consecutively affected stops of the direction on screen, with
    /// the coordinates of each dotted overlay already mapped (spec S7).
    var incidentRuns: [BusIncidentRunLayer] = []
    /// One badge per run, at its middle stop (spec S7).
    var incidentBadges: [IncidentRunBadge] = []
    /// Stops with a facility alert active right now, one entry per physical
    /// stop code (spec S7).
    var facilityStops: [FacilityStationMark] = []
}

/// One run of affected stops of the bus map with the coordinates of its
/// overlay (spec S7).
private struct BusIncidentRunLayer: Identifiable {
    let run: IncidentRun
    /// Coordinates of the dotted overlay; empty when the run has nothing to
    /// draw, which is the case the map skips.
    let coordinates: [CLLocationCoordinate2D]

    /// Identity of the run it draws, so the overlay survives a re-derivation.
    var id: Int { run.id }
}

/// Hollow stop dot on the bus map (spec S6, mockup `V3Markers`): white with a
/// stroke in the line colour, sitting on the route. The 44 pt frame around the
/// dot is the touch target.
private struct HollowStopDot: View {
    let colorHex: String

    var body: some View {
        Circle()
            .fill(Color.white)
            .frame(width: 14, height: 14)
            .overlay(Circle().stroke(Color(hex: colorHex), lineWidth: 3))
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }
}

/// Moving bus marker: the line-colored bus pictogram rotated along its
/// heading, the line name in an upright chip above it, and the destination
/// label below when zoomed in (spec S2, S3).
///
/// Kept after the S6 rework: `BusMapScreen` no longer draws it, but the FGC
/// and Tot maps (T4b) still do; the parent removes it during cleanup (T7).
struct BusMarker: View {
    let line: BusLine
    let destination: String
    /// Rotation of the pictogram: `heading - 90 - cameraHeading`, the same rule
    /// the east-facing metro pictograms use, so 0 degrees means heading east.
    let rotation: Double
    /// The destination label below the pictogram: zoomed in, and only for the
    /// direction on screen (map-perf S14c).
    let showLabel: Bool
    /// Whether the line-name chip draws at all: only for the direction on
    /// screen, so a dimmed bus of the other direction is a bare pictogram
    /// instead of reading as a ghost copy of a selected one (map-perf S14c).
    let showName: Bool
    /// 1 for the direction on screen, 0.55 for the other one (spec S3).
    let opacity: Double

    /// Width and height of the pictogram in points: the 54x32 bus asset
    /// rendered at the size its README asks for (spec S2).
    static let markerSize = CGSize(width: 42, height: 24.9)

    /// Asset name of the bus for a line: `bus-<colorHex>` when the catalog has
    /// that colour, `bus-default` otherwise (spec S3). The lookup is by name at
    /// runtime, so a colour the generator did not emit degrades instead of
    /// drawing nothing.
    static func assetName(for line: BusLine) -> String {
        let name = "bus-\(line.colorHex.lowercased())"
        return UIImage(named: name) != nil ? name : "bus-default"
    }

    var body: some View {
        // MapKit centers an annotation on its coordinate, so only the pictogram
        // rotates and `rotationEffect` keeps the layout size at 42x24.9 pt: the
        // chip and the label live in overlays on that unrotated frame, which
        // adds nothing to the marker size and always stays upright.
        Image(Self.assetName(for: line))
            .resizable()
            .frame(width: Self.markerSize.width, height: Self.markerSize.height)
            .rotationEffect(.degrees(rotation))
            .overlay(alignment: .top) {
                // The line name has to stay readable while the bus turns, so
                // it is a chip of its own outside the rotated image (spec S2).
                // Only the direction on screen carries it (map-perf S14c).
                if showName {
                    Text(line.name)
                        .font(.caption2.bold())
                        .foregroundStyle(Color(hex: line.textColorHex))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color(hex: line.colorHex)))
                        .fixedSize()
                        .offset(y: -20)
                }
            }
            .opacity(opacity)
            .overlay(alignment: .bottom) {
                if showLabel {
                    Text(destination)
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.thinMaterial, in: Capsule())
                        .fixedSize()
                        .offset(y: 22)
                }
            }
            .accessibilityLabel("Bus \(line.name) cap a \(destination)")
    }
}

/// Strip for a line whose iBus feed reports no bus right now (spec S9). Same
/// shape as the compact metro notice, with its own wording.
private struct NoBusesCard: View {
    var body: some View {
        HStack(spacing: 10) {
            Image("icon-realtime-off")
                .resizable()
                .scaledToFit()
                .frame(width: 20, height: 20)
                .foregroundStyle(.secondary)
            Text("Cap bus en servei ara")
                .font(.footnote.bold())
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        // A notice, not a control: the map stays pannable under it.
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }
}
