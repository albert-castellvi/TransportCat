import CoreLocation
import MapKit
import SwiftUI

/// Live map of the FGC network (spec S7): every line drawn dimmed except the
/// selected one, its stations as dots and its trains as markers gliding along
/// the track, fed by the single `FGCNetworkState.shared` poller.
///
/// It mirrors `BusMapScreen` on purpose — same header shape, same marker view,
/// same camera bookkeeping — so the mode selector changes the data and never
/// the layout. The polling task is owned by `RootView` (one `.task(id: mode)`
/// for both FGC screens), so this view only reads the shared state.
///
/// Spec S11 lives here too: the rider's dot when location is authorized, and
/// the router's line, place and vehicle focuses.
@MainActor
struct FGCMapScreen: View {
    /// Hook for the nearby sheet (spec S13, T5): called after the location
    /// button centers the camera on the rider. Defaults to nothing.
    var onLocate: (() -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The line chips write this key and both FGC screens read it, so the map
    /// and the lines list always show the same line (spec S7, S9).
    @AppStorage("fgcSelectedLine") private var selectedLineCode = FGCLinePicker.defaultLineCode
    /// Stations of the line on screen, recomputed on every change of line or
    /// topology, never while the body renders (the join is geometric, so a
    /// 10 Hz re-render must not re-project a hundred stations).
    @State private var shownStations: [FGCStation] = []
    /// Map coordinates of every layer's polylines, converted once per topology
    /// instead of on every 10 Hz redraw (spec S8). Keyed by layer code, which
    /// is unique inside the FGC network.
    @State private var lineCoordinates: [String: [[CLLocationCoordinate2D]]] = [:]
    /// The train whose glass card is open (spec S6): tapping a vehicle marks
    /// it with the halo plus its destination label and opens the card above
    /// the accessory. The card reads the live train from the shared state by
    /// id.
    @State private var selectedVehicle: MapVehicle?
    /// The train whose full sheet is open (spec S8): a vehicle focus opens it
    /// directly, with the follow toggle inside. A snapshot copy: the sheet
    /// reads the live train from the shared state by id.
    @State private var sheetVehicle: MapVehicle?
    /// Train the camera is following, or nil (spec S8).
    @State private var followingVehicleID: String?
    /// Router focus intents waiting for their data (spec S11): the station to
    /// center on once the topology exists, and the train id that is not in the
    /// glide yet.
    @State private var pendingPlaceFocus: Place?
    @State private var pendingVehicleFocusID: String?
    /// Line the pending vehicle focus asked for. A focus owns only the one line
    /// change it caused: any later change means the rider moved on and the
    /// pending focus is dropped instead of disabling the reset (spec S11).
    @State private var pendingVehicleFocusLine: String?
    /// Where the camera was commanded to last, so the continuous callback can
    /// tell our own follow animation from a pan by the rider.
    @State private var followAnchor: GeoPoint?
    /// Camera bearing in degrees clockwise from north: the train markers
    /// rotate against it so they keep facing along the track whatever the
    /// rider does with the map, exactly like the bus markers (spec S7).
    @State private var cameraHeading: Double = 0
    /// Span the camera follows with: kept current by every camera change so
    /// re-centering never zooms (spec S8).
    @State private var cameraSpan = MapScreen.barcelonaRegion.span
    // Named type instead of `Self` on purpose: a stored-property initializer has
    // no instance context, so the spelled-out type name is the form that is
    // guaranteed to compile.
    @State private var cameraPosition: MapCameraPosition = .region(MapScreen.barcelonaRegion)

    /// Explicit because the private stored properties make the memberwise
    /// initializer private; RootView passes the nearby hook (spec S13).
    init(onLocate: (() -> Void)? = nil) {
        self.onLocate = onLocate
    }

    private var state: FGCNetworkState { FGCNetworkState.shared }

    /// App-wide navigation intent (spec S11): FGC focuses are handled here and
    /// cleared by this screen.
    private var router: AppRouter { AppRouter.shared }
    /// Device location for the blue dot (spec S11).
    private var location: LocationService { LocationService.shared }
    /// Whether the map may draw the rider's position at all; a denied
    /// permission simply leaves the dot and the button away (S11).
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

    /// The line actually on screen: the stored code when it is selectable,
    /// otherwise the first selectable line.
    private var shownLineCode: String {
        FGCLinePicker.resolve(selected: selectedLineCode, from: state.lineLayers)
    }

    private var shownLayer: MapLineLayer? {
        state.lineLayers.first { $0.code == shownLineCode }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                mapArea
                    // The placeholder and the map swap with a short fade when
                    // the topology first arrives (polish pass).
                    .animation(AppMotion.smooth(reduceMotion: reduceMotion), value: shownLayer != nil)
            }
            // Spec S1: no header — the mode selector and the line chips move
            // to the bottom accessory, the map fills the screen under the
            // status bar, and the v2 chrome lives in overlays.
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
            // Spec S6: the selected vehicle's glass card, above the bottom
            // accessory (the safe-area alignment keeps it clear of it).
            .overlay(alignment: .bottom) {
                vehicleCard
                    .padding(.bottom, 8)
                    .animation(AppMotion.smooth(reduceMotion: reduceMotion), value: selectedVehicle?.id)
            }
            .animation(AppMotion.smooth(reduceMotion: reduceMotion), value: hasLiveSignal)
            // Changing the FGC line is a selection, so it clicks, like the bus.
            .sensoryFeedback(.selection, trigger: selectedLineCode)
            .onAppear {
                refreshMapContent()
                fitCamera()
                // A focus may have switched the mode to FGC and created this
                // screen around it (spec S11).
                applyFocus(router.pendingFocus)
                resolvePendingFocuses()
            }
            .onChange(of: router.pendingFocus) { _, destination in
                applyFocus(destination)
            }
            .onChange(of: selectedLineCode) { _, newCode in
                // A new line is a new subject: drop the old train and refit —
                // unless a focus just moved to this line and is about to open
                // its sheet (spec S11). Only the line change the focus asked
                // for is exempt: a second change means the rider moved on, so
                // a focus whose train never showed up is dropped here instead
                // of disabling this reset for the rest of the session.
                let focusOwnsThisChange = pendingVehicleFocusID != nil
                    && pendingVehicleFocusLine == newCode
                if !focusOwnsThisChange {
                    pendingVehicleFocusID = nil
                    pendingVehicleFocusLine = nil
                    selectedVehicle = nil
                    sheetVehicle = nil
                    followingVehicleID = nil
                    fitCamera()
                }
                refreshMapContent()
            }
            // The layers themselves, not their count: a reload that returns the
            // same number of lines must refresh the dots and the coordinates
            // too (spec S8).
            .onChange(of: state.lineLayers) { _, _ in
                refreshMapContent()
                if pendingPlaceFocus == nil, pendingVehicleFocusID == nil {
                    fitCamera()
                }
                resolvePendingFocuses()
            }
            // The glide updates `vehicles` at 10 Hz: while a train is followed,
            // the camera re-centers on it, keeping the span (spec S8). A
            // vehicle focus waiting for its train is checked on the same tick.
            .onChange(of: state.vehicles) { _, vehicles in
                followVehicle(in: vehicles)
                resolvePendingVehicleFocus()
            }
        }
        // Spec S1: the map screens show no navigation bar.
        .toolbar(.hidden, for: .navigationBar)
        // The train sheet is presented by the stack itself and declares its
        // detents here, as the metro and bus station sheets learned to do.
        // Closing the sheet stops the follow (spec S8).
        .sheet(item: $sheetVehicle, onDismiss: { followingVehicleID = nil }) { vehicle in
            FGCTrainSheet(
                trainID: vehicle.id,
                allowFollow: true,
                followingVehicleID: $followingVehicleID
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    // MARK: - The v2 chrome (spec S1)

    /// The selected vehicle's glass card (spec S6, mockup `V3Markers`): the
    /// line badge, the destination, the stop the train serves next (D1: no
    /// minutes — the FGC feed publishes neither) and where the position comes
    /// from. Closing it keeps the map as it was; nothing else changes.
    @ViewBuilder
    private var vehicleCard: some View {
        if let vehicle = selectedVehicle, let layer = shownLayer {
            MapGlassCard(
                badgeText: layer.code,
                badgeColorHex: layer.colorHex,
                title: "Cap a \(vehicle.label)",
                onClose: { selectedVehicle = nil }
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    FGCVehicleCardRows(vehicleID: vehicle.id)
                    // The existing train sheet: occupancy, stops and
                    // "follow" stay reachable from a plain tap.
                    Button {
                        sheetVehicle = vehicle
                    } label: {
                        Label("Més detalls", systemImage: "info.circle")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .transition(.opacity)
        }
    }

    /// The status capsule over the map (spec S2): freshness of the 30 s FGC
    /// poll and connectivity in one glass capsule, like every map here. It
    /// joins the chrome when the first poll has an answer — good or bad —
    /// exactly the moment the old chip row appeared.
    @ViewBuilder
    private var statusCapsule: some View {
        if hasLiveSignal || !isOnline {
            FreshnessChip(
                updatedAt: state.arrivalsUpdatedAt,
                lastAttemptFailed: state.lastPollFailed,
                feedEmpty: false
            )
            .transition(AppMotion.chipTransition)
        }
    }

    /// Whether the live feed has said anything yet: a successful poll or a
    /// failed one. Before that the capsule would only read "Sense dades"
    /// online, while offline the saved-data wording is already the answer.
    private var hasLiveSignal: Bool {
        state.arrivalsUpdatedAt != nil || state.lastPollFailed
    }

    /// 44 pt glass location button, top-right of the map (spec S3, mockup
    /// `V2Main`). It keeps today's behavior: an undecided rider gets the
    /// permission request the map used to offer in its own button, an
    /// authorized one gets the camera centered on their last fix at the zoom
    /// already on screen — the system `MapUserLocationButton` behavior.
    /// While the nearby sheet is open (spec S13) the button is filled with
    /// the accent color and a white glyph, on every map.
    /// `onLocate` is the T5 hook for the nearby sheet.
    private var locationButton: some View {
        Button {
            locate()
        } label: {
            if router.isNearbyPresented {
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

    // MARK: - Map

    @ViewBuilder
    private var mapArea: some View {
        if let layer = shownLayer {
            lineMap(layer: layer)
                .transition(.opacity)
        } else if let message = state.errorMessage {
            // Topology never loaded: state the reason, the FGC portal needs
            // no credentials to retry.
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
    private func lineMap(layer: MapLineLayer) -> some View {
        Map(position: $cameraPosition) {
            if isLocationAuthorized {
                // The rider's own dot (spec S11). Unauthorized, it is simply
                // not drawn; a denied permission never blocks the map.
                UserAnnotation()
            }
            ForEach(state.lineLayers) { line in
                // Every line of the network (S11): the selected one at full
                // color and width 5, the rest dimmed to 25 % and width 3. The
                // opacity goes into the stroke color because a map overlay has
                // no view opacity to set, exactly as on the bus map (spec S7).
                ForEach(line.polylines.indices, id: \.self) { index in
                    // Coordinates converted once per topology (spec S8): the
                    // 10 Hz tick must not map every line of the network again.
                    let coordinates = polylineCoordinates(of: line, at: index)
                    if coordinates.count >= 2 {
                        MapPolyline(coordinates: coordinates)
                            .stroke(
                                Color(hex: line.colorHex).opacity(line.code == layer.code ? 1 : 0.25),
                                style: StrokeStyle(
                                    lineWidth: line.code == layer.code ? 5 : 3,
                                    lineCap: .round,
                                    lineJoin: .round
                                )
                            )
                    }
                }
            }
            ForEach(shownStations) { station in
                if let point = station.point {
                    // Empty title: the dot only shows where the line stops.
                    Annotation("", coordinate: CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)) {
                        FGCStationDot(colorHex: layer.colorHex)
                            .accessibilityLabel("Estació \(station.name)")
                    }
                }
            }
            ForEach(state.vehicles.filter { $0.lineCode == layer.code }) { vehicle in
                // Empty title: the marker's VoiceOver label says the destination.
                Annotation("", coordinate: CLLocationCoordinate2D(latitude: vehicle.position.latitude, longitude: vehicle.position.longitude)) {
                    Button {
                        selectedVehicle = vehicle
                    } label: {
                        FGCVehicleMarker(
                            vehicle: vehicle,
                            cameraHeading: cameraHeading,
                            isSelected: selectedVehicle?.id == vehicle.id
                        )
                    }
                    .buttonStyle(.plain)
                    // A train has to say "Tren" to VoiceOver (spec S7), plus
                    // the occupancy summary when FGC publishes one (spec S18).
                    .accessibilityLabel(trainAccessibilityLabel(vehicle, layerCode: layer.code))
                }
            }
        }
        .mapStyle(.standard(elevation: .flat))
        // Spec S1: the map fills the screen under the status bar; the chrome
        // overlays above keep their safe-area insets.
        .ignoresSafeArea(.container, edges: .top)
        .onMapCameraChange(frequency: .onEnd) { context in
            cameraHeading = context.camera.heading
            cameraSpan = context.region.span
        }
        // Pan detection for the follow (spec S8): a change whose center is not
        // near the point we last commanded is the rider moving the map, so the
        // camera releases the train. Zoom keeps the follow.
        .onMapCameraChange(frequency: .continuous) { context in
            cameraSpan = context.region.span
            guard followingVehicleID != nil, let anchor = followAnchor else { return }
            let tolerance = max(Self.followPanToleranceDegrees, cameraSpan.latitudeDelta * 0.05)
            let center = context.region.center
            if abs(center.latitude - anchor.latitude) > tolerance
                || abs(center.longitude - anchor.longitude) > tolerance {
                followingVehicleID = nil
            }
        }
        .overlay {
            if state.isLoading {
                ProgressView()
                    .padding(12)
                    .background(.thinMaterial, in: Circle())
            }
        }
        // Attribution of the feed drawn here (spec S10).
        .overlay(alignment: .bottomLeading) {
            Text("Dades: FGC · CC BY 4.0")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.thinMaterial, in: Capsule())
                .padding(12)
                .allowsHitTesting(false)
        }
        .animation(AppMotion.smooth(duration: 0.35, reduceMotion: reduceMotion), value: state.lineLayers.count)
    }

    // MARK: - Camera and station bookkeeping

    /// Re-derives everything the map draws from the shared topology: the
    /// station dots of the line on screen and the coordinates of every line's
    /// polylines (specs S7, S8). Called on appear and on every change of line
    /// or topology, never from the 10 Hz render path.
    private func refreshMapContent() {
        shownStations = FGCLineStations.stations(for: shownLayer, in: state.stations)
        var coordinates: [String: [[CLLocationCoordinate2D]]] = [:]
        for layer in state.lineLayers {
            coordinates[layer.code] = layer.polylines.map { Self.mapCoordinates(of: $0) }
        }
        lineCoordinates = coordinates
    }

    /// Coordinates of one polyline of a layer, already converted when the
    /// topology arrived (spec S8). Empty while the derivation has not run,
    /// which only happens before the first `onAppear` of the screen.
    private func polylineCoordinates(of line: MapLineLayer, at index: Int) -> [CLLocationCoordinate2D] {
        guard let polylines = lineCoordinates[line.code], polylines.indices.contains(index) else { return [] }
        return polylines[index]
    }

    /// Map coordinates of a polyline (spec S8): the one place the `GeoPoint` →
    /// `CLLocationCoordinate2D` conversion happens, so it runs when the
    /// topology changes and never on a 10 Hz redraw.
    private static func mapCoordinates(of points: [GeoPoint]) -> [CLLocationCoordinate2D] {
        points.map { point in
            CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
        }
    }

    /// Fit the camera to the whole selected line, on first load and on every
    /// change of line, so a long diagonal line is not cut off by the fixed
    /// Barcelona region (spec S7).
    private func fitCamera() {
        guard let layer = shownLayer else { return }
        let points = layer.polylines.flatMap { $0 }
        guard let region = Self.region(fitting: points) else { return }
        cameraSpan = region.span
        withAnimation(AppMotion.smooth(duration: 0.35, reduceMotion: reduceMotion)) {
            cameraPosition = .region(region)
        }
    }

    /// Re-center on the followed train if it is still in the feed (spec S8).
    /// The span is kept as it is so following never zooms.
    private func followVehicle(in vehicles: [MapVehicle]) {
        guard let id = followingVehicleID,
              let vehicle = vehicles.first(where: { $0.id == id }) else { return }
        followAnchor = vehicle.position
        cameraPosition = .region(
            MKCoordinateRegion(
                center: CLLocationCoordinate2D(
                    latitude: vehicle.position.latitude,
                    longitude: vehicle.position.longitude
                ),
                span: cameraSpan
            )
        )
    }

    // MARK: - Focus (spec S11)

    /// Applies a router focus addressed to FGC (spec S11). A focus for
    /// another operator is left untouched for its own map.
    private func applyFocus(_ destination: Destination?) {
        guard let destination, destination.operator == AppModeCode.fgc else { return }
        switch destination {
        case .line(_, let code):
            selectedLineCode = code
            router.clearFocus()
        case .place(let place):
            guard place.kind == .fgcStation else { return }
            pendingPlaceFocus = place
            resolvePendingPlaceFocus()
        case .vehicle(_, let lineCode, let vehicleID):
            pendingVehicleFocusID = vehicleID
            pendingVehicleFocusLine = lineCode
            let changedLine = selectedLineCode != lineCode
            selectedLineCode = lineCode
            // A line change re-triggers through the glide tick; with the same
            // line on screen nothing else will, so try now (spec S11, S10).
            if !changedLine {
                resolvePendingVehicleFocus()
            }
            router.clearFocus()
        }
    }

    /// Re-runs every pending resolution. Idempotent: with no pending intent
    /// it does nothing, so every data-arrival trigger may call it.
    private func resolvePendingFocuses() {
        resolvePendingPlaceFocus()
        resolvePendingVehicleFocus()
    }

    /// Centers a pending station focus once the topology exists (spec S11).
    private func resolvePendingPlaceFocus() {
        guard let place = pendingPlaceFocus, shownLayer != nil else { return }
        pendingPlaceFocus = nil
        centerCamera(on: place.position)
        router.clearFocus()
    }

    /// Opens the train sheet with follow on once the focused vehicle exists
    /// in the glide (spec S11, S10).
    private func resolvePendingVehicleFocus() {
        guard let vehicleID = pendingVehicleFocusID,
              let vehicle = state.vehicles.first(where: { $0.id == vehicleID }) else { return }
        pendingVehicleFocusID = nil
        pendingVehicleFocusLine = nil
        sheetVehicle = vehicle
        followingVehicleID = vehicle.id
        centerCamera(on: vehicle.position)
    }

    /// Zoom to a station or a train and re-center on it (spec S11).
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

    /// The VoiceOver text of a train marker: line and destination (spec S7),
    /// plus the occupancy summary when FGC publishes one (spec S18). The glide
    /// publishes `MapVehicle`s without cars, so the live train behind the
    /// vehicle is looked up by its stable id.
    private func trainAccessibilityLabel(_ vehicle: MapVehicle, layerCode: String) -> String {
        var label = "Tren \(layerCode) cap a \(vehicle.label)"
        if let train = state.trains.first(where: { $0.id == vehicle.id }),
           let occupancy = FGCOccupancy.summary(train) {
            label += ". \(occupancy)"
        }
        return label
    }

    /// Smallest span kept per axis, so a short line whose points sit close
    /// together does not zoom the map to street level.
    private static let minSpanDegrees = 0.01

    /// Region that contains every polyline point, padded by 30 % per axis so
    /// the end stations do not touch the edge of the screen. Nil for an empty
    /// list. Same rule as the bus map's fit.
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

    /// Span a focus centers with: close enough for the station or the train
    /// sheet to be about something on screen (spec S11). The same zoom the bus
    /// map uses for its stop and vehicle focuses.
    private static let focusSpanDegrees = 0.01

    /// Floor of the pan-detection tolerance, in degrees: below it our own
    /// 10 Hz follow commands would read as the rider moving the map.
    private static let followPanToleranceDegrees = 0.002
}

/// Station dot on the FGC map: a hollow circle with the white center and the
/// line-colored ring, the unified station look of spec S6 (the vehicles are
/// solid, the stations are hollow).
private struct FGCStationDot: View {
    let colorHex: String

    var body: some View {
        Circle()
            .fill(.white)
            .frame(width: 11, height: 11)
            .overlay(Circle().stroke(Color(hex: colorHex), lineWidth: 3))
    }
}

/// One FGC train marker on the map (spec S6, mockup `V3Markers`): the
/// unified marker in the line color with the train glyph and the heading
/// wedge — never a line label, which only the selected vehicle shows as its
/// destination chip below. `Equatable` so a 10 Hz glide tick that changed
/// nothing visible skips the body.
private struct FGCVehicleMarker: View, Equatable {
    let vehicle: MapVehicle
    let cameraHeading: Double
    let isSelected: Bool

    var body: some View {
        VehicleMarkerView(
            colorHex: vehicle.colorHex,
            glyph: .train,
            headingDegrees: vehicle.heading - cameraHeading,
            isEstimated: false,
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

/// Rows of the selected train's glass card, read live from the shared state
/// by the train id (spec S6): the stop the train serves next and its
/// punctuality, then where the position comes from.
private struct FGCVehicleCardRows: View {
    let vehicleID: String

    private var state: FGCNetworkState { FGCNetworkState.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let train = state.trains.first(where: { $0.id == vehicleID }) {
                stopRow(train)
                Text(train.isOnTime ? "Puntual" : "Amb retard")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(train.isOnTime ? Color.green : Color.orange)
            }
            // FGC positions are GPS live data (spec S3): never an estimate.
            VehiclePositionSource(isEstimated: false, estimatedText: "")
        }
    }

    /// The station the train is stopped at, or its next announced stop: the
    /// same rule the train sheet's "Aturat a" applies (spec S8).
    @ViewBuilder
    private func stopRow(_ train: FGCTrain) -> some View {
        if let stopCode = train.stoppedAtStopCode {
            Label("Aturat a \(stationName(for: stopCode))", systemImage: "pause.circle.fill")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else if let stopCode = train.nextStopCodes.first {
            Label("Propera parada: \(stationName(for: stopCode))", systemImage: "arrow.right.circle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    /// Station name of a stop code, falling back to the code when the catalog
    /// does not know it, exactly as the train sheet does.
    private func stationName(for code: String) -> String {
        state.stations.first { $0.code == code }?.name ?? code
    }
}
