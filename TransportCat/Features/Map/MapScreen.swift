import MapKit
import SwiftUI

/// Live map of one line: physical route as a polyline overlay, stations and
/// computed train positions as annotations.
@MainActor
struct MapScreen: View {
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
    @State private var selectedStation: Station?
    /// Train whose sheet is open (spec S10). A snapshot copy: the sheet reads
    /// the live position from the line state by id, like the FGC map.
    @State private var selectedTrain: TrainPosition?
    /// Station whose `IncidentSheet` is open (spec S9).
    @State private var incidentStation: Station?
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
    /// Camera bearing of the visible map region, in degrees clockwise from
    /// north. The train pictograms are rotated against it so they keep facing
    /// along the track whatever the user does with the map (S2).
    @State private var cameraHeading: Double = 0
    /// Latitude span currently on screen, used to decide whether the train
    /// labels are drawn at all (S3).
    @State private var latitudeSpan: Double = MapScreen.barcelonaRegion.span.latitudeDelta
    // Named type instead of `Self` on purpose: a stored-property initializer has
    // no instance context, so the spelled-out type name is the form that is
    // guaranteed to compile.
    @State private var cameraPosition: MapCameraPosition = .region(MapScreen.barcelonaRegion)

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

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ModeSelector()
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                LinePicker(selectedLineCode: $selectedLineCode)
                chipsRow
                mapArea
                    // The placeholder and the map swap with a short fade when
                    // the line's state first arrives (polish pass) and when its
                    // stations do: until then the placeholder stays up instead
                    // of an empty map (spec S2).
                    .animation(AppMotion.smooth(reduceMotion: reduceMotion), value: mapAreaPhase)
            }
            // Changing the line is a selection, so it clicks (polish pass).
            .sensoryFeedback(.selection, trigger: selectedLineCode)
            .navigationTitle("Mapa")
            .navigationBarTitleDisplayMode(.inline)
            // The loader task must live on the always-visible container: the
            // map itself only renders once LineState exists, so a task attached
            // there would never start (infinite "Carregant…").
            .task(id: selectedLineCode) {
                guard let client = app.client else { return }
                // Spec S4: a line loaded on this screen is reused, so a line
                // switch or a return to the tab repaints from memory and only
                // resumes polling. `run()` loads the topology the first time.
                let state = cachedLineState(for: selectedLine, client: client)
                self.lineState = state
                await state.run()
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
                // A new line is a new subject: drop the old train, its follow
                // and any incident sheet, as the FGC map does (S10).
                selectedTrain = nil
                followingTrainID = nil
                incidentStation = nil
            }
        }
        // The station sheet is presented by the stack itself and declares its
        // detents here instead of inside the presented view: presenting it from
        // a view nested in the stack is what left its first rows under the
        // navigation bar in build 23 (spec S9).
        .sheet(item: $selectedStation) { station in
            StationDetailView(station: station, line: selectedLine)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $incidentStation) { station in
            IncidentSheet(
                alerts: incidentAlerts(for: station),
                title: "\(selectedLine.displayName) · \(station.name)"
            )
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

    /// Freshness of the line data and count of its incidents (spec S7).
    private var chipsRow: some View {
        HStack(spacing: 8) {
            if let state = lineState {
                FreshnessChip(lineState: state)
                    .transition(AppMotion.chipTransition)
            }
            IncidentsChip(
                lineCode: selectedLineCode,
                lineDisplayName: selectedLine.displayName
            )
            .transition(AppMotion.chipTransition)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 16)
        .padding(.bottom, 8)
        // The freshness chip joins the row the moment the line's state exists:
        // fade and shrink it in instead of a pop (polish pass).
        .animation(AppMotion.smooth(reduceMotion: reduceMotion), value: lineState != nil)
        // Same for the incidents chip when the alerts feed first answers.
        .animation(AppMotion.smooth(reduceMotion: reduceMotion), value: app.alertsUpdatedAt)
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
        let terminalCodes = Self.terminalStationCodes(in: state.stations)
        // Active incidents grouped into runs (spec S9). Recomputed per render
        // the same way the diagram recomputes them per poll; the grouping
        // itself is pure and tested (`IncidentSegments`).
        let incidents = IncidentIndex.incidents(
            for: app.alerts,
            stations: state.stations,
            lineCode: selectedLine.code
        )
        let runs = IncidentSegments.runs(stations: state.stations, incidents: incidents)
        Map(position: $cameraPosition) {
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
                        StationMarker(line: selectedLine, terminal: terminalCodes.contains(station.code))
                    }
                }
            }
            // Each run of consecutive affected stations overlays the track
            // with a red dashed line (spec S9).
            ForEach(runs) { run in
                if let coordinates = Self.runOverlayPoints(for: run, state: state) {
                    MapPolyline(coordinates: coordinates)
                        .stroke(
                            Self.incidentRed,
                            style: StrokeStyle(lineWidth: 5, lineCap: .round, dash: [7, 5])
                        )
                }
            }
            // A red warning triangle per affected station, drawn after the
            // station dots so it sits on top (spec S9).
            ForEach(runs.flatMap(\.stations)) { station in
                Annotation(station.name, coordinate: CLLocationCoordinate2D(latitude: station.latitude, longitude: station.longitude)) {
                    Button {
                        incidentStation = station
                    } label: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(Self.incidentRed)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Incidència a \(station.name)")
                }
            }
            ForEach(state.positions) { position in
                // Empty title: the destination is already on the marker.
                Annotation("", coordinate: CLLocationCoordinate2D(latitude: position.position.latitude, longitude: position.position.longitude)) {
                    // Tapping the train opens its sheet with the follow
                    // button (spec S10).
                    Button {
                        selectedTrain = position
                    } label: {
                        TrainMarker(
                            imageName: "train-\(trainLine(for: position).assetKey)",
                            destination: position.destination,
                            rotation: position.heading - 90 - cameraHeading,
                            showLabel: latitudeSpan < Self.labelSpanThreshold,
                            theoretical: position.isTheoretical
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Tren \(trainLine(for: position).displayName) cap a \(position.destination)")
                }
            }
            // The rider's own dot once permission was granted (spec S11).
            if isLocationAuthorized {
                UserAnnotation()
            }
        }
        .mapStyle(.standard(elevation: .flat))
        .mapControls {
            // The system locate button only where it can do something (S11).
            if isLocationAuthorized {
                MapUserLocationButton()
            }
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            cameraHeading = context.camera.heading
            latitudeSpan = context.region.span.latitudeDelta
            cameraSpan = context.region.span
        }
        // Pan detection for the follow (spec S10): a change whose center is
        // not near the point we last commanded is the rider moving the map,
        // so the camera releases the train. Zoom keeps the follow.
        .onMapCameraChange(frequency: .continuous) { context in
            latitudeSpan = context.region.span.latitudeDelta
            cameraSpan = context.region.span
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
        .overlay(alignment: .bottomTrailing) {
            // No decision taken yet: one tap asks for permission. A denied
            // permission shows nothing here and never blocks the map (S11).
            // Sits above the polling spinner so the two never overlap.
            if isLocationNotDetermined {
                Button {
                    location.requestWhenInUse()
                } label: {
                    Image(systemName: "location.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 40, height: 40)
                        .background(.thinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Activa la ubicació")
                .padding(.trailing, 16)
                .padding(.bottom, 72)
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
            // Five lines publish no arrivals: an empty map would read as a bug,
            // so the reason is stated, in a compact strip at the top so it does
            // not cover the line itself (spec S8).
            if state.isFeedEmpty {
                NoRealtimeDataCard(compact: true, theoretical: state.isTheoretical)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
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
        // A line change swaps the polyline, the stations and the trains
        // wholesale, and they arrive with the first poll: fade the overlays
        // in on the change instead of popping them onto an empty map
        // (polish pass, no Map rebuild).
        .animation(AppMotion.smooth(duration: 0.35, reduceMotion: reduceMotion), value: state.stations.map(\.code))
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

    // MARK: - Incidents on the map (S9)

    /// The red of a service incident, the same `IncidentSheet` gives its
    /// severity icon.
    private static let incidentRed = Color(hex: "D92D20")

    /// Coordinates of the red dashed overlay of one run: the line's geometry
    /// between the run's end stations, falling back to straight station-to-
    /// station segments when the geometry cannot carry the run (spec S9).
    private static func runOverlayPoints(for run: IncidentRun, state: LineState) -> [CLLocationCoordinate2D]? {
        let points: [GeoPoint]?
        if let geometry = state.geometry, let onTrack = IncidentSegments.trackPolyline(for: run, geometry: geometry) {
            points = onTrack
        } else {
            points = IncidentSegments.stationPolyline(for: run)
        }
        guard let points, points.count >= 2 else { return nil }
        return points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
    }

    /// The active alerts behind one station's warning marker (spec S9), taken
    /// from the same `IncidentIndex` the markers come from so the sheet and
    /// the map can never disagree.
    private func incidentAlerts(for station: Station) -> [ServiceAlert] {
        let incidents = IncidentIndex.incidents(
            for: app.alerts,
            stations: [station],
            lineCode: selectedLine.code
        )
        let ids = Set((incidents[station.code] ?? []).map(\.alertID))
        return app.alerts.filter { ids.contains($0.id) }
    }

    // MARK: - Follow (S10)

    /// Re-center on the followed train if it is still on the line (spec S10).
    /// The span is kept as it is so following never zooms.
    private func followTrain(in positions: [TrainPosition]) {
        guard let id = followingTrainID,
              let train = positions.first(where: { $0.id == id }) else { return }
        followAnchor = train.position
        cameraPosition = .region(
            MKCoordinateRegion(
                center: CLLocationCoordinate2D(
                    latitude: train.position.latitude,
                    longitude: train.position.longitude
                ),
                span: cameraSpan
            )
        )
    }

    /// Floor of the pan-detection tolerance, in degrees: below it our own
    /// 10 Hz follow commands would read as the rider moving the map (S10).
    private static let followPanToleranceDegrees = 0.002

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
            incidentStation = nil
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

    /// Below this visible latitude span the destination labels are drawn; above
    /// it they overlapped each other on the busy lines (S3).
    private static let labelSpanThreshold = 0.05

    /// The line a train marker belongs to: the code of the position itself,
    /// falling back to the line on screen when the feed reports an unknown one.
    private func trainLine(for position: TrainPosition) -> MetroLine {
        MetroLine.line(forCode: position.lineCode) ?? selectedLine
    }

    /// Codes of the two end stations of the shown line, which get the terminal
    /// marker instead of the plain one (S4).
    private static func terminalStationCodes(in stations: [Station]) -> Set<Int> {
        guard let first = stations.min(by: { $0.orderInLine < $1.orderInLine }),
              let last = stations.max(by: { $0.orderInLine < $1.orderInLine }) else { return [] }
        return [first.code, last.code]
    }
}

/// Station marker on the map: the pre-rendered dot tinted with the line color
/// (S4), 18 pt for a normal station and 22 pt for a terminal.
private struct StationMarker: View {
    let line: MetroLine
    let terminal: Bool

    var body: some View {
        Image("\(terminal ? "terminal" : "station")-\(line.assetKey)")
            .resizable()
            .frame(width: size, height: size)
    }

    private var size: CGFloat { terminal ? 22 : 18 }
}

/// Moving train marker with its destination label (S1).
private struct TrainMarker: View {
    let imageName: String
    let destination: String
    /// Rotation applied to the pictogram: `heading - 90 - cameraHeading`, the
    /// assets face east and the map may be rotated by the user.
    let rotation: Double
    let showLabel: Bool
    /// A train computed from the timetable, not a live one: drawn faded so the
    /// rider can tell it apart at a glance (spec S7).
    let theoretical: Bool

    var body: some View {
        // MapKit centers an annotation on its coordinate, so only the image is
        // rotated and `rotationEffect` keeps the layout size at 42x18.67 pt
        // (the 72:32 aspect of the v2 train art): the label lives in an overlay
        // on that unrotated frame, which adds nothing to the marker size and
        // always stays upright.
        Image(imageName)
            .resizable()
            .frame(width: 42, height: 18.67)
            .rotationEffect(.degrees(rotation))
            .opacity(theoretical ? 0.7 : 1)
            .overlay(alignment: .bottom) {
                if showLabel {
                    Text(destination)
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.thinMaterial, in: Capsule())
                        .fixedSize()
                        // Measured from the frame's bottom edge, 9.33 pt under
                        // the marker center. The pictogram is 42 pt long, so
                        // heading north or south it reaches 21 pt under that
                        // center: this offset puts the label's top edge just
                        // below it, so the two never overlap in any heading.
                        .offset(y: 20)
                }
            }
            .accessibilityLabel("Tren \(destination)")
    }
}
