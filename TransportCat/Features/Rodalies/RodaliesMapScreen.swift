import CoreLocation
import MapKit
import SwiftUI

/// Live map of the Rodalies de Catalunya nucleus: the selected line's track in
/// its own colour, its stations as dots and Renfe's live trains as markers
/// gliding along the track, all fed by the single `RodaliesNetworkState.shared`
/// poller that `RootView` owns.
///
/// It mirrors `FGCMapScreen` on purpose — same header shape, same marker view,
/// same camera bookkeeping and the same follow rule — so switching mode changes
/// the data and never the layout. Only the selected line is drawn: the nucleus
/// has 19 lines and drawing all of them at once would be noise.
@MainActor
struct RodaliesMapScreen: View {
    /// Hook for the nearby sheet: called after the location button centers the
    /// camera on the rider. Defaults to nothing.
    var onLocate: (() -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The line the chip, the Parades screen and this map share.
    @AppStorage(RodaliesLineSelection.storageKey)
    private var selectedLineCode = RodaliesLineSelection.defaultLineCode
    /// Stations of the line on screen, recomputed when the line or the topology
    /// changes, never on the 10 Hz redraw.
    @State private var shownStations: [RodaliesStation] = []
    /// Map coordinates of the shown line's polylines, converted once per
    /// topology instead of on every glide tick.
    @State private var lineCoordinates: [CLLocationCoordinate2D] = []
    /// The train whose glass card is open.
    @State private var selectedVehicle: MapVehicle?
    /// The train whose sheet is open. A snapshot copy: the sheet reads the live
    /// train from the shared state by id.
    @State private var sheetVehicle: MapVehicle?
    /// Train the camera is following, or nil.
    @State private var followingVehicleID: String?
    /// Router place focus waiting for the topology to exist.
    @State private var pendingPlaceFocus: Place?
    /// Where the camera was commanded to last, so the continuous callback can
    /// tell our own follow animation from a pan by the rider.
    @State private var followAnchor: GeoPoint?
    /// Deadline of a camera flight started by a focus.
    @State private var focusFlightEndsAt: Date?
    /// Station whose sheet is open.
    @State private var selectedPlace: Place?
    /// Camera bearing in degrees clockwise from north: markers rotate against
    /// it so they keep facing along the track whatever the rider does.
    @State private var cameraHeading: Double = 0
    /// Span the camera follows with: kept current by every camera change so
    /// re-centering never zooms.
    @State private var cameraSpan = MapScreen.barcelonaRegion.span
    @State private var cameraPosition: MapCameraPosition = .region(MapScreen.barcelonaRegion)

    /// Explicit because the private stored properties make the memberwise
    /// initializer private; `RootView` passes the nearby hook.
    init(onLocate: (() -> Void)? = nil) {
        self.onLocate = onLocate
    }

    private var state: RodaliesNetworkState { RodaliesNetworkState.shared }
    private var router: AppRouter { AppRouter.shared }
    private var location: LocationService { LocationService.shared }

    private var isLocationAuthorized: Bool {
        location.authorization == .authorizedWhenInUse || location.authorization == .authorizedAlways
    }

    private var isLocationNotDetermined: Bool {
        location.authorization == .notDetermined
    }

    private var isOnline: Bool {
        ConnectivityMonitor.shared.isOnline
    }

    /// The line actually on screen: the stored code when the topology knows it,
    /// otherwise its first line.
    private var shownLineCode: String {
        RodaliesLineSelection.resolve(selected: selectedLineCode, from: state.lines)
    }

    private var shownLine: RodaliesLine? {
        state.lines.first { $0.code == shownLineCode }
    }

    /// The drawable track of the line on screen. `RodaliesLine` carries the
    /// colours and the termini; the polylines live in the shared map layer.
    private var shownLayer: MapLineLayer? {
        state.lineLayers.first { $0.code == shownLineCode }
    }

    var body: some View {
        NavigationStack {
            mapArea
                .animation(AppMotion.smooth(reduceMotion: reduceMotion), value: shownLine != nil)
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
                .overlay(alignment: .bottom) {
                    vehicleCard
                        .padding(.bottom, 8)
                        .animation(AppMotion.smooth(reduceMotion: reduceMotion), value: selectedVehicle?.id)
                }
                .animation(AppMotion.smooth(reduceMotion: reduceMotion), value: hasLiveSignal)
                .sensoryFeedback(.selection, trigger: selectedLineCode)
                .onAppear {
                    // The topology ships inside the app: loading it here makes
                    // the map draw on the first frame instead of waiting for
                    // the poller's task to be scheduled.
                    if state.lines.isEmpty { state.loadTopology() }
                    refreshMapContent()
                    fitCamera()
                    applyFocus(router.pendingFocus)
                    resolvePendingFocuses()
                }
                .onChange(of: router.pendingFocus) { _, destination in
                    applyFocus(destination)
                }
                .onChange(of: selectedLineCode) { _, _ in
                    // A new line is a new subject: drop the old train and refit.
                    selectedVehicle = nil
                    sheetVehicle = nil
                    followingVehicleID = nil
                    fitCamera()
                    refreshMapContent()
                    resolvePendingPlaceFocus()
                }
                .onChange(of: followingVehicleID) { _, vehicleID in
                    if vehicleID == nil {
                        followAnchor = nil
                        focusFlightEndsAt = nil
                    }
                }
                .onChange(of: state.lineLayers) { _, _ in
                    refreshMapContent()
                    if pendingPlaceFocus == nil {
                        fitCamera()
                    }
                    resolvePendingPlaceFocus()
                }
                .onChange(of: state.vehicles) { _, vehicles in
                    followVehicle(in: vehicles)
                }
        }
        .toolbar(.hidden, for: .navigationBar)
        // The train sheet is presented by the stack and declares its detents
        // here, as the FGC one does. Closing it stops the follow.
        .sheet(item: $sheetVehicle, onDismiss: { followingVehicleID = nil }) { vehicle in
            RodaliesTrainSheet(
                vehicleID: vehicle.id,
                allowFollow: true,
                followingVehicleID: $followingVehicleID
            )
            .presentationDetents([.fraction(0.35), .medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $selectedPlace) { place in
            RodaliesStationSheet(place: place)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    // MARK: - Chrome

    /// The selected train's glass card: destination, next stop, punctuality and
    /// where the position comes from, with the way into the full sheet.
    @ViewBuilder
    private var vehicleCard: some View {
        if let vehicle = selectedVehicle, let line = shownLine {
            MapGlassCard(
                badgeText: line.code,
                badgeColorHex: line.colorHex,
                title: vehicle.label.isEmpty
                    ? String(localized: "Destí desconegut")
                    : String(localized: "Cap a \(vehicle.label)"),
                onClose: { selectedVehicle = nil }
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    RodaliesVehicleCardRows(vehicleID: vehicle.id)
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
    /// failed one. Before that the capsule would only read "Sense dades".
    private var hasLiveSignal: Bool {
        state.arrivalsUpdatedAt != nil || state.lastPollFailed
    }

    /// 44 pt glass location button, top-right of the map, filling with the
    /// accent colour while the "A prop teu" sheet is open, like every map here.
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
        if let line = shownLine, shownLayer != nil {
            lineMap(line: line)
                .transition(.opacity)
        } else if let message = state.errorMessage {
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
    private func lineMap(line: RodaliesLine) -> some View {
        Map(position: $cameraPosition) {
            if isLocationAuthorized {
                UserAnnotation()
            }
            // Only the selected line: the track in its own colour.
            if lineCoordinates.count >= 2 {
                MapPolyline(coordinates: lineCoordinates)
                    .stroke(
                        Color(hex: line.colorHex),
                        style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round)
                    )
            }
            ForEach(shownStations) { station in
                Annotation(
                    "",
                    coordinate: CLLocationCoordinate2D(
                        latitude: station.latitude,
                        longitude: station.longitude
                    )
                ) {
                    Button {
                        selectedPlace = RodaliesPlaces.place(for: station)
                    } label: {
                        RodaliesStationDot(colorHex: line.colorHex)
                            .accessibilityLabel("Estació \(station.name)")
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            ForEach(state.vehicles.filter { $0.lineCode == line.code }) { vehicle in
                Annotation(
                    "",
                    coordinate: CLLocationCoordinate2D(
                        latitude: vehicle.position.latitude,
                        longitude: vehicle.position.longitude
                    )
                ) {
                    Button {
                        selectedVehicle = vehicle
                    } label: {
                        RodaliesVehicleMarker(
                            vehicle: vehicle,
                            cameraHeading: cameraHeading,
                            isSelected: selectedVehicle?.id == vehicle.id
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(markerAccessibilityLabel(vehicle))
                }
            }
        }
        .mapStyle(.standard(elevation: .flat))
        .ignoresSafeArea(.container, edges: .top)
        .onMapCameraChange(frequency: .onEnd) { context in
            cameraHeading = context.camera.heading
            cameraSpan = context.region.span
        }
        // Pan detection for the follow: a change whose center is not near the
        // point we last commanded is the rider moving the map, so the camera
        // releases the train. Zoom keeps the follow.
        .onMapCameraChange(frequency: .continuous) { context in
            cameraSpan = context.region.span
            guard !isFocusFlightInProgress else { return }
            guard followingVehicleID != nil, let anchor = followAnchor else { return }
            let tolerance = max(Self.followPanToleranceDegrees, cameraSpan.latitudeDelta * 0.05)
            let center = context.region.center
            if abs(center.latitude - anchor.latitude) > tolerance
                || abs(center.longitude - anchor.longitude) > tolerance {
                followingVehicleID = nil
                followAnchor = nil
            }
        }
        .overlay {
            if state.isLoading {
                ProgressView()
                    .padding(12)
                    .background(.thinMaterial, in: Circle())
            }
        }
        .overlay(alignment: .bottomTrailing) {
            Text("Dades: Renfe · CC BY 4.0")
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

    /// VoiceOver text of a train marker: line, and the destination only when
    /// the timetable knows it.
    private func markerAccessibilityLabel(_ vehicle: MapVehicle) -> String {
        if vehicle.label.isEmpty {
            return String(localized: "Tren de la \(vehicle.lineCode)")
        }
        return String(localized: "Tren de la \(vehicle.lineCode) cap a \(vehicle.label)")
    }

    // MARK: - Camera and station bookkeeping

    /// Re-derives what the map draws from the shared topology: the station dots
    /// of the line on screen and the coordinates of its polylines.
    private func refreshMapContent() {
        shownStations = state.stations(ofLine: shownLineCode)
        if let points = shownLayer?.polylines.first {
            lineCoordinates = points.map { point in
                CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
            }
        } else {
            lineCoordinates = []
        }
    }

    /// Fit the camera to the whole selected line, on first load and on every
    /// change of line, so a long line is not cut off by the fixed region.
    private func fitCamera() {
        guard let layer = shownLayer else { return }
        let points = layer.polylines.flatMap { $0 }
        guard let region = Self.region(fitting: points) else { return }
        cameraSpan = region.span
        withAnimation(AppMotion.smooth(duration: 0.35, reduceMotion: reduceMotion)) {
            cameraPosition = .region(region)
        }
    }

    /// Re-center on the followed train if it is still in the feed. The span is
    /// kept so following never zooms, and the centre moves south by half of the
    /// height the sheet covers, so the train lands in the visible band.
    private func followVehicle(in vehicles: [MapVehicle]) {
        guard let id = followingVehicleID,
              let vehicle = vehicles.first(where: { $0.id == id }) else { return }
        let offset = cameraSpan.latitudeDelta * Self.vehicleSheetCoverFraction / 2
        let center = CLLocationCoordinate2D(
            latitude: vehicle.position.latitude - offset,
            longitude: vehicle.position.longitude
        )
        followAnchor = GeoPoint(latitude: center.latitude, longitude: center.longitude)
        cameraPosition = .region(MKCoordinateRegion(center: center, span: cameraSpan))
    }

    // MARK: - Focus

    /// Applies a router focus addressed to Rodalies. A focus for another
    /// operator is left untouched for its own map.
    private func applyFocus(_ destination: Destination?) {
        guard let destination, destination.operator == AppModeCode.rodalies else { return }
        switch destination {
        case .line(_, let code):
            selectedLineCode = code
            router.clearFocus()
        case .place(let place):
            guard place.kind == .rodaliesStation else { return }
            pendingPlaceFocus = place
            resolvePendingPlaceFocus()
        case .vehicle(_, let lineCode, _):
            // No Rodalies surface builds a vehicle focus today; selecting its
            // line is the honest half-answer and keeps the map on the right
            // subject instead of leaving the intent pending forever.
            selectedLineCode = lineCode
            router.clearFocus()
        }
    }

    private func resolvePendingFocuses() {
        resolvePendingPlaceFocus()
    }

    /// Centers a pending station focus once the topology exists, after making
    /// sure a line serving the station is the one on screen: the focus must
    /// center where the app actually draws the station and its trains.
    private func resolvePendingPlaceFocus() {
        guard let place = pendingPlaceFocus, shownLine != nil else { return }
        if let serving = state.lines.first(where: { place.lineCodes.contains($0.code) }),
           shownLineCode != serving.code {
            // Switch first and keep the focus pending: the line change's own
            // onChange refreshes the stations and re-runs this.
            selectedLineCode = serving.code
            return
        }
        pendingPlaceFocus = nil
        centerCamera(on: place.position)
        router.clearFocus()
    }

    /// Zoom to a station and re-center on it.
    private func centerCamera(on point: GeoPoint) {
        let span = MKCoordinateSpan(
            latitudeDelta: Self.focusSpanDegrees,
            longitudeDelta: Self.focusSpanDegrees
        )
        cameraSpan = span
        // Our own animation moves the camera across the map: the pan detector
        // must not read it as the rider dragging the map away.
        focusFlightEndsAt = Date().addingTimeInterval(Self.focusFlightDuration)
        withAnimation(AppMotion.smooth(reduceMotion: reduceMotion)) {
            cameraPosition = .region(
                MKCoordinateRegion(
                    center: CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude),
                    span: span
                )
            )
        }
    }

    /// Smallest span kept per axis, so a short line does not zoom to street
    /// level.
    private static let minSpanDegrees = 0.01

    /// Region that contains every polyline point, padded by 30 % per axis.
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

    /// Span a focus centers with: the same zoom the other maps use.
    private static let focusSpanDegrees = 0.01

    /// Floor of the pan-detection tolerance, in degrees.
    private static let followPanToleranceDegrees = 0.002

    /// Fraction of the map height the train sheet covers at its compact detent.
    private static let vehicleSheetCoverFraction = 0.35

    /// How long a focus flight keeps the pan detector quiet.
    private static let focusFlightDuration: TimeInterval = 0.5

    private var isFocusFlightInProgress: Bool {
        guard let deadline = focusFlightEndsAt else { return false }
        return Date() < deadline
    }
}

/// Station dot on the Rodalies map: a hollow circle with the white centre and
/// the line-coloured ring, the unified station look the other maps share.
private struct RodaliesStationDot: View {
    let colorHex: String

    var body: some View {
        Circle()
            .fill(.white)
            .frame(width: 11, height: 11)
            .overlay(Circle().stroke(Color(hex: colorHex), lineWidth: 3))
    }
}

/// One Rodalies train marker: the unified marker in the line colour with the
/// line code in the circle, so two trains of the selected line still read as
/// trains of that line. `Equatable` so a glide tick that changed nothing skips
/// the body.
private struct RodaliesVehicleMarker: View, Equatable {
    let vehicle: MapVehicle
    let cameraHeading: Double
    let isSelected: Bool

    var body: some View {
        VehicleMarkerView(
            colorHex: vehicle.colorHex,
            glyph: .code(vehicle.lineCode),
            headingDegrees: vehicle.heading - cameraHeading,
            isEstimated: false,
            isSelected: isSelected,
            size: 30
        )
        .overlay(alignment: .bottom) {
            if isSelected, !vehicle.label.isEmpty {
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

/// Rows of the selected train's glass card, read live from the shared state by
/// the marker id: the stop the feed says it is heading to, its punctuality and
/// where the position comes from. Renfe positions are GPS fixes, never
/// estimates.
private struct RodaliesVehicleCardRows: View {
    let vehicleID: String

    private var state: RodaliesNetworkState { RodaliesNetworkState.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let train = state.liveTrain(id: vehicleID) {
                if let stopID = train.nextStopID {
                    Label(
                        "Pròxima: \(state.stationName(id: stopID))",
                        systemImage: "arrow.right.circle"
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
                let status = RodaliesDepartureText.delay(seconds: train.delaySeconds)
                Text(status.text)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(delayColor(status))
            }
            VehiclePositionSource(isEstimated: false, estimatedText: "")
        }
    }

    /// Amber for a delay, green for a train the feed confirms on time, and the
    /// secondary ink when the feed says nothing about this one.
    private func delayColor(_ status: RodaliesDelayStatus) -> Color {
        if status.isDelayed { return Color(hex: "F59E0B") }
        if case .onTime = status { return .green }
        return .secondary
    }
}
