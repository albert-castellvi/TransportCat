import CoreLocation
import MapKit
import SwiftUI
import UIKit

/// Live map of one bus line (spec S3): the route of both directions in the
/// line color, the stops of the direction on screen as dots, and the buses
/// placed from the arrivals the poll collected (spec S4).
///
/// Stops with an incident active right now carry a red warning marker that
/// opens `IncidentSheet` (spec S9), tapping a bus opens `BusVehicleSheet` with
/// the follow mechanics of the FGC map (spec S10), and the rider's own dot
/// plus the router's focus intents belong to spec S11.
///
/// The buses are the `bus-<colorHex>` pictograms of the asset catalog, rotated
/// to their heading, with the line name in an upright chip (spec S2).
///
/// It mirrors `MapScreen` on purpose — same header shape, same chips, same
/// camera bookkeeping — so switching mode with the selector at the top changes
/// the data and never the layout.
@MainActor
struct BusMapScreen: View {
    /// Whether bus is the mode on screen (spec S13). `RootView` keeps all four
    /// map screens mounted (spec S12), so this flag — and not the view's
    /// lifecycle — is what says whether the screen may load and poll: an
    /// off-screen mode does neither, and coming back resumes on the retained
    /// `BusLineState` without fetching its topology again.
    let isActive: Bool
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
    /// `ID_SENTIT` of the direction the `Anada`/`Tornada` chip selects: full
    /// opacity for its route and its buses, dimmed for the other one (spec S3).
    @State private var selectedDirectionID = 1
    @State private var showLinePicker = false
    /// Stop whose sheet is open (spec S6).
    @State private var selectedStop: BusStop?
    /// Stop whose incident sheet is open (spec S9).
    @State private var incidentStop: BusStop?
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
    /// Camera bearing in degrees clockwise from north: the bus markers rotate
    /// against it so they keep facing along the route whatever the user does
    /// with the map, exactly like the metro train markers.
    @State private var cameraHeading: Double = 0
    /// Latitude span on screen, which decides whether stop dots and bus
    /// labels are drawn at all (spec S3).
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

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                mapArea
                    // The placeholder and the map swap with a short fade when
                    // the line's state first arrives (polish pass).
                    .animation(AppMotion.smooth(reduceMotion: reduceMotion), value: lineState != nil)
            }
            // Changing the bus line is a selection, so it clicks (polish pass).
            .sensoryFeedback(.selection, trigger: store.selectedLine?.code)
            .navigationTitle("Mapa")
            .navigationBarTitleDisplayMode(.inline)
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
                // A new line is a new subject: drop the old bus and its
                // follow, exactly as the FGC map does for its train.
                selectedBus = nil
                followingVehicleID = nil
                resolvePendingFocuses()
            }
            .onChange(of: lineState?.directions.map(\.id)) { _, _ in
                // Topology of the (new) line arrived: place focuses waiting
                // for it can open their sheet now (spec S11), and the map
                // overlay (routes and incident stops) can be derived from it
                // once instead of on every render (spec S8).
                refreshMapOverlay()
                resolvePendingFocuses()
            }
            // The direction chip changes which route is drawn at full colour
            // and whose stops carry the incident markers, so the overlay is
            // re-derived on the change (spec S8).
            .onChange(of: selectedDirectionID) { _, _ in
                refreshMapOverlay()
            }
            // A new bus alerts feed re-derives the incident stops (spec S8).
            .onChange(of: app.busAlertsUpdatedAt) { _, _ in
                refreshMapOverlay()
            }
            .sheet(isPresented: $showLinePicker) {
                BusLinePickerSheet(store: store) { line in
                    store.selectedLineCode = line.code
                }
            }
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
        // FGC train sheet does.
        .sheet(item: $selectedBus, onDismiss: { followingVehicleID = nil }) { bus in
            if let state = lineState {
                BusVehicleSheet(
                    state: state,
                    positionID: bus.id,
                    allowFollow: true,
                    followingVehicleID: $followingVehicleID
                )
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
        // The alerts behind one stop's warning marker (spec S9).
        // `IncidentSheet` declares its own detents.
        .sheet(item: $incidentStop) { stop in
            if let line = store.selectedLine {
                IncidentSheet(
                    alerts: incidentAlerts(for: stop, line: line),
                    title: "\(line.name) · \(stop.name)"
                )
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 0) {
            ModeSelector()
                .padding(.horizontal, 16)
                .padding(.top, 8)
            BusLineButton(line: store.selectedLine) {
                showLinePicker = true
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            directionControl
            chipsRow
        }
    }

    /// "Anada · <destí>" / "Tornada · <destí>" (spec S3). Hidden while the
    /// stops of the line have not arrived, when there is nothing to choose.
    @ViewBuilder
    private var directionControl: some View {
        if let state = lineState, !state.directions.isEmpty {
            Picker("Direcció", selection: $selectedDirectionID) {
                ForEach(state.directions) { direction in
                    Text("\(direction.name) · \(direction.destinationName)")
                        .tag(direction.id)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    /// Freshness of the bus poll and count of the line's incidents (spec S3,
    /// S5, S7).
    @ViewBuilder
    private var chipsRow: some View {
        if let line = store.selectedLine {
            HStack(spacing: 8) {
                if let state = lineState {
                    FreshnessChip(
                        updatedAt: state.arrivalsUpdatedAt,
                        lastAttemptFailed: state.lastPollFailed,
                        feedEmpty: state.hasNoBuses
                    )
                    .transition(AppMotion.chipTransition)
                }
                IncidentsChip(busLineCode: String(line.code), lineDisplayName: line.name)
                    .transition(AppMotion.chipTransition)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 16)
            .padding(.bottom, 8)
            // The freshness chip joins the row the moment the line's state
            // exists: fade and shrink it in instead of a pop (polish pass).
            .animation(AppMotion.smooth(reduceMotion: reduceMotion), value: lineState != nil)
            // Same for the incidents chip when the bus alerts feed first answers.
            .animation(AppMotion.smooth(reduceMotion: reduceMotion), value: app.busAlertsUpdatedAt)
        }
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
        // The routes and the incident stops come from `mapOverlay`, derived
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
                    MapPolyline(coordinates: coordinates)
                        .stroke(
                            Color(hex: line.colorHex).opacity(direction.id == selectedDirectionID ? 1 : 0.4),
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
                            StopDot(colorHex: line.colorHex)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Parada \(stop.name)")
                    }
                }
            }
            ForEach(mapOverlay.incidentStops) { stop in
                // Red warning marker on every stop with an incident right now
                // (spec S9). Not zoom-gated: an incident is worth seeing from
                // the whole-line view down.
                Annotation("", coordinate: CLLocationCoordinate2D(latitude: stop.latitude, longitude: stop.longitude)) {
                    Button {
                        incidentStop = stop
                    } label: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Incidència a la parada \(stop.name)")
                }
            }
            ForEach(state.positions) { position in
                // Empty title: the destination is already on the marker.
                Annotation("", coordinate: CLLocationCoordinate2D(latitude: position.train.position.latitude, longitude: position.train.position.longitude)) {
                    // Tapping a bus opens its sheet with the follow button
                    // (spec S10), like the FGC map does for its trains.
                    Button {
                        selectedBus = position
                    } label: {
                        BusMarker(
                            line: line,
                            destination: position.train.destination,
                            rotation: position.train.heading - 90 - cameraHeading,
                            showLabel: latitudeSpan < Self.labelSpanThreshold,
                            opacity: position.directionID == selectedDirectionID ? 1 : 0.55
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .mapStyle(.standard(elevation: .flat))
        .mapControls {
            if isLocationAuthorized {
                MapUserLocationButton()
            }
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            cameraHeading = context.camera.heading
            latitudeSpan = context.region.span.latitudeDelta
            cameraSpan = context.region.span
        }
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
        .overlay(alignment: .top) {
            // A line with no bus in the feed reads as a broken map, so the
            // reason is stated in a strip that does not cover the route (S9).
            if state.hasNoBuses {
                NoBusesCard()
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            }
        }
        .overlay(alignment: .bottom) {
            if state.totalStopCount > 0 {
                sourceStrip(state: state)
            }
        }
        .onChange(of: state.directions.map(\.id)) { _, ids in
            if !ids.contains(selectedDirectionID) {
                selectedDirectionID = ids.first ?? 1
            }
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
        .overlay(alignment: .topTrailing) {
            // S11: before a decision the map offers a button that asks for
            // when-in-use permission; after one it never appears again.
            if location.authorization == .notDetermined {
                Button {
                    location.requestWhenInUse()
                } label: {
                    Image(systemName: "location.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .padding(10)
                        .background(.thinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Activa la ubicació")
                .padding(.trailing, 16)
                .padding(.top, 8)
            }
        }
        // A line change swaps both route polylines, the stop dots and the
        // buses wholesale, and they arrive with the first poll: fade the
        // overlays in on the change instead of popping them onto an empty
        // map (polish pass, no Map rebuild).
        .animation(AppMotion.smooth(duration: 0.35, reduceMotion: reduceMotion), value: state.directions.map(\.id))
    }

    /// The strip that says where the buses come from (spec S3, S9): the
    /// positions are estimated from arrivals, never from a GPS feed, and the
    /// rider has to be able to tell that without leaving the screen.
    private func sourceStrip(state: BusLineState) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "clock")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text("Posició estimada a partir de les arribades a \(state.polledStopCount) de \(state.totalStopCount) parades (TMB iBus). \(state.trackedBusCount) busos seguits.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                // Full sentence, never clipped by the card height.
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .accessibilityElement(children: .combine)
    }

    /// The direction the chips select, falling back to the first one of the
    /// line so a line that only publishes one direction still draws its stops.
    private func shownDirection(in state: BusLineState) -> BusDirection? {
        state.directions.first { $0.id == selectedDirectionID } ?? state.directions.first
    }

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

    /// Stops of the line with an incident active right now (spec S9), from an
    /// `IncidentIndex` pass over the same `AppModel.busAlerts` source
    /// `BusStopSheet` reads. One marker per physical stop code: the same stop
    /// of both directions shares it, preferring the direction on screen.
    ///
    /// Static and takes its inputs explicitly because the map derives it when
    /// the directions, the direction chip or the alerts change, never from the
    /// 10 Hz render path (spec S8).
    private static func incidentStops(
        in state: BusLineState,
        shown: BusDirection?,
        alerts: [ServiceAlert]
    ) -> [BusStop] {
        guard !alerts.isEmpty else { return [] }
        let code = String(state.line.code)
        let allStops = state.directions.flatMap(\.stops)
        guard !allStops.isEmpty else { return [] }
        let incidents = IncidentIndex.incidents(
            for: alerts,
            stations: allStops.map { $0.asStation(lineCode: code) },
            lineCode: code
        )
        guard !incidents.isEmpty else { return [] }
        let ordered = (shown.map { [$0] } ?? []) + state.directions.filter { $0.id != shown?.id }
        var seen: Set<Int> = []
        var result: [BusStop] = []
        for stop in ordered.flatMap(\.stops) where incidents[stop.code] != nil && !seen.contains(stop.code) {
            seen.insert(stop.code)
            result.append(stop)
        }
        return result
    }

    /// Re-derives the map overlay of the line on screen: the coordinates of
    /// both routes and the stops with an incident (spec S8). Called when the
    /// topology, the direction chip or the alerts feed changes.
    private func refreshMapOverlay() {
        guard let state = lineState else {
            mapOverlay = BusMapOverlay()
            return
        }
        var routes: [Int: [CLLocationCoordinate2D]] = [:]
        for direction in state.directions {
            routes[direction.id] = Self.mapCoordinates(of: direction.route.points)
        }
        mapOverlay = BusMapOverlay(
            routeCoordinates: routes,
            incidentStops: Self.incidentStops(
                in: state,
                shown: shownDirection(in: state),
                alerts: app.activeBusAlerts(affecting: String(state.line.code))
            )
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

    /// The feed alerts behind one stop's warning marker: the ids `IncidentIndex`
    /// matched for the stop (spec S9), resolved back into the `ServiceAlert`
    /// values `IncidentSheet` lists.
    private func incidentAlerts(for stop: BusStop, line: BusLine) -> [ServiceAlert] {
        guard let state = lineState else { return [] }
        let ids = Set(incidents(for: stop, in: state, line: line).map(\.alertID))
        return app.busAlerts
            .filter { ids.contains($0.id) }
            .sorted { $0.id < $1.id }
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
        guard let state = lineState, !state.directions.isEmpty else { return }
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
        guard let vehicleID = pendingVehicleFocusID, let state = lineState else { return }
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
    private func followBus(in state: BusLineState) {
        guard let id = followingVehicleID,
              let position = state.positions.first(where: { $0.id == id }) else { return }
        followAnchor = position.train.position
        cameraPosition = .region(
            MKCoordinateRegion(
                center: CLLocationCoordinate2D(
                    latitude: position.train.position.latitude,
                    longitude: position.train.position.longitude
                ),
                span: cameraSpan
            )
        )
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

    /// Below this visible latitude span the destination labels are drawn; above
    /// it they overlap each other, as on the metro map (spec S3).
    private static let labelSpanThreshold = 0.05

    /// Span a focus centers with: close enough for the stop sheet or the bus
    /// sheet to be about something on screen, under the stop-dot threshold so
    /// the neighborhood stays drawn (spec S11).
    private static let focusSpanDegrees = 0.01

    /// Floor of the pan-detection tolerance, in degrees: below it our own
    /// 10 Hz follow commands would read as the rider moving the map. The FGC
    /// map's constant, copied because both maps release the follow the same
    /// way (spec S10).
    private static let followPanToleranceDegrees = 0.002
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
/// direction chip and the alerts feed (spec S8): the polyline of each direction
/// and the stops that carry an incident marker.
///
/// The 10 Hz position tick re-evaluates `body` but never rebuilds this value,
/// so neither the incident grouping nor the `GeoPoint` →
/// `CLLocationCoordinate2D` mapping of a route happens on the render path.
private struct BusMapOverlay {
    /// Coordinates of each direction's route, keyed by `ID_SENTIT`.
    var routeCoordinates: [Int: [CLLocationCoordinate2D]] = [:]
    /// Stops with an incident active right now, one entry per physical stop
    /// code (spec S9).
    var incidentStops: [BusStop] = []
}

/// Stop dot on the bus map: a small line-colored circle with a white stroke.
private struct StopDot: View {
    let colorHex: String

    var body: some View {
        Circle()
            .fill(Color(hex: colorHex))
            .frame(width: 10, height: 10)
            .overlay(Circle().stroke(.white, lineWidth: 1.5))
    }
}

/// Moving bus marker: the line-colored bus pictogram rotated along its
/// heading, the line name in an upright chip above it, and the destination
/// label below when zoomed in (spec S2, S3).
struct BusMarker: View {
    let line: BusLine
    let destination: String
    /// Rotation of the pictogram: `heading - 90 - cameraHeading`, the same rule
    /// the east-facing metro pictograms use, so 0 degrees means heading east.
    let rotation: Double
    let showLabel: Bool
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
                Text(line.name)
                    .font(.caption2.bold())
                    .foregroundStyle(Color(hex: line.textColorHex))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color(hex: line.colorHex)))
                    .fixedSize()
                    .offset(y: -20)
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
