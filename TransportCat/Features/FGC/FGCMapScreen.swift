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
struct FGCMapScreen: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The line chips write this key and both FGC screens read it, so the map
    /// and the lines list always show the same line (spec S7, S9).
    @AppStorage("fgcSelectedLine") private var selectedLineCode = FGCLinePicker.defaultLineCode
    /// Stations of the line on screen, recomputed on every change of line or
    /// topology, never while the body renders (the join is geometric, so a
    /// 10 Hz re-render must not re-project a hundred stations).
    @State private var shownStations: [FGCStation] = []
    /// The train whose sheet is open (spec S8). A snapshot copy: the sheet
    /// reads the live train from the shared state by id.
    @State private var selectedVehicle: MapVehicle?
    /// Train the camera is following, or nil (spec S8).
    @State private var followingVehicleID: String?
    /// Router focus intents waiting for their data (spec S11): the station to
    /// center on once the topology exists, and the train id that is not in the
    /// glide yet.
    @State private var pendingPlaceFocus: Place?
    @State private var pendingVehicleFocusID: String?
    /// Where the camera was commanded to last, so the continuous callback can
    /// tell our own follow animation from a pan by the rider.
    @State private var followAnchor: GeoPoint?
    /// Camera bearing in degrees clockwise from north: the train markers
    /// rotate against it so they keep facing along the track whatever the
    /// rider does with the map, exactly like the bus markers (spec S7).
    @State private var cameraHeading: Double = 0
    /// Latitude span on screen, which decides whether the train labels are
    /// drawn at all, and part of the pan-detection tolerance.
    @State private var latitudeSpan: Double = MapScreen.barcelonaRegion.span.latitudeDelta
    /// Span the camera follows with: kept current by every camera change so
    /// re-centering never zooms (spec S8).
    @State private var cameraSpan = MapScreen.barcelonaRegion.span
    // Named type instead of `Self` on purpose: a stored-property initializer has
    // no instance context, so the spelled-out type name is the form that is
    // guaranteed to compile.
    @State private var cameraPosition: MapCameraPosition = .region(MapScreen.barcelonaRegion)

    init() {}

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
            VStack(spacing: 0) {
                header
                mapArea
                    // The placeholder and the map swap with a short fade when
                    // the topology first arrives (polish pass).
                    .animation(AppMotion.smooth(reduceMotion: reduceMotion), value: shownLayer != nil)
            }
            // Changing the FGC line is a selection, so it clicks, like the bus.
            .sensoryFeedback(.selection, trigger: selectedLineCode)
            .navigationTitle("Mapa")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                refreshStations()
                fitCamera()
                // A focus may have switched the mode to FGC and created this
                // screen around it (spec S11).
                applyFocus(router.pendingFocus)
                resolvePendingFocuses()
            }
            .onChange(of: router.pendingFocus) { _, destination in
                applyFocus(destination)
            }
            .onChange(of: selectedLineCode) { _, _ in
                // A new line is a new subject: drop the old train and refit —
                // unless a focus just moved to this line and is about to open
                // its sheet (spec S11).
                if pendingVehicleFocusID == nil {
                    selectedVehicle = nil
                    followingVehicleID = nil
                    fitCamera()
                }
                refreshStations()
            }
            .onChange(of: state.lineLayers.count) { _, _ in
                refreshStations()
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
        // The train sheet is presented by the stack itself and declares its
        // detents here, as the metro and bus station sheets learned to do.
        // Closing the sheet stops the follow (spec S8).
        .sheet(item: $selectedVehicle, onDismiss: { followingVehicleID = nil }) { vehicle in
            FGCTrainSheet(
                trainID: vehicle.id,
                allowFollow: true,
                followingVehicleID: $followingVehicleID
            )
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
            FGCLinePicker(layers: state.lineLayers, selectedLineCode: $selectedLineCode)
            chipsRow
        }
    }

    /// Freshness of the 30 s FGC poll (spec S7). It joins the header when the
    /// first poll has an answer — good or bad — and fades out the placeholder
    /// row the way the bus chip arrives with its line state. No incidents
    /// chip: FGC publishes no line-disruption feed (spec S10).
    @ViewBuilder
    private var chipsRow: some View {
        HStack(spacing: 8) {
            if hasLiveSignal {
                FreshnessChip(
                    updatedAt: state.arrivalsUpdatedAt,
                    lastAttemptFailed: state.lastPollFailed,
                    feedEmpty: false
                )
                .transition(AppMotion.chipTransition)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 16)
        .padding(.bottom, 8)
        .animation(AppMotion.smooth(reduceMotion: reduceMotion), value: hasLiveSignal)
    }

    /// Whether the live feed has said anything yet: a successful poll or a
    /// failed one. Before that the chip would only read "Sense dades".
    private var hasLiveSignal: Bool {
        state.arrivalsUpdatedAt != nil || state.lastPollFailed
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
                    MapPolyline(coordinates: line.polylines[index].map { point in
                        CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
                    })
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
                // Empty title: the destination is already on the marker.
                Annotation("", coordinate: CLLocationCoordinate2D(latitude: vehicle.position.latitude, longitude: vehicle.position.longitude)) {
                    Button {
                        selectedVehicle = vehicle
                    } label: {
                        BusMarker(
                            line: Self.busLine(for: layer),
                            destination: vehicle.label,
                            rotation: vehicle.heading - 90 - cameraHeading,
                            showLabel: latitudeSpan < Self.labelSpanThreshold,
                            opacity: 1
                        )
                    }
                    .buttonStyle(.plain)
                    // The reused bus marker says "Bus"; a train has to say
                    // "Tren" to VoiceOver (spec S7).
                    .accessibilityLabel("Tren \(layer.code) cap a \(vehicle.label)")
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
        // Pan detection for the follow (spec S8): a change whose center is not
        // near the point we last commanded is the rider moving the map, so the
        // camera releases the train. Zoom keeps the follow.
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
        .animation(AppMotion.smooth(duration: 0.35, reduceMotion: reduceMotion), value: state.lineLayers.count)
    }

    // MARK: - Camera and station bookkeeping

    /// Re-derives the station dots of the line on screen from the shared
    /// topology (spec S7). Called on appear and on every change of line or
    /// topology, never from the 10 Hz render path.
    private func refreshStations() {
        shownStations = FGCLineStations.stations(for: shownLayer, in: state.stations)
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
        selectedVehicle = vehicle
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

    /// `BusMarker` draws from a `BusLine`; the FGC map reuses that view with
    /// the layer's own code and colors, so the two live maps paint vehicles
    /// identically (spec S7). Only the fields the marker reads are filled.
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

    /// Below this visible latitude span the destination labels are drawn;
    /// above it they overlap each other, as on the bus and metro maps (S7).
    private static let labelSpanThreshold = 0.05

    /// Span a focus centers with: close enough for the station or the train
    /// sheet to be about something on screen (spec S11). The same zoom the bus
    /// map uses for its stop and vehicle focuses.
    private static let focusSpanDegrees = 0.01

    /// Floor of the pan-detection tolerance, in degrees: below it our own
    /// 10 Hz follow commands would read as the rider moving the map.
    private static let followPanToleranceDegrees = 0.002
}

/// Station dot on the FGC map: a small circle in the line color with a white
/// stroke, the same shape the bus map uses for its stops (spec S7).
private struct FGCStationDot: View {
    let colorHex: String

    var body: some View {
        Circle()
            .fill(Color(hex: colorHex))
            .frame(width: 10, height: 10)
            .overlay(Circle().stroke(.white, lineWidth: 1.5))
    }
}
