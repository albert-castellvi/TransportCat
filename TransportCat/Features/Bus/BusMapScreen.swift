import MapKit
import SwiftUI

/// Live map of one bus line (spec S3): the route of both directions in the
/// line color, the stops of the direction on screen as dots, and the buses
/// placed from the arrivals the poll collected (spec S4).
///
/// It mirrors `MapScreen` on purpose — same header shape, same chips, same
/// camera bookkeeping — so switching mode with the selector at the top changes
/// the data and never the layout.
struct BusMapScreen: View {
    @EnvironmentObject private var app: AppModel
    /// Catalog and picker state, shared with the bus Línies screen so both
    /// always show the same line (spec S2). Read as a plain property: the
    /// `@Observable` store registers the view on its own when the body reads
    /// it, so there is no second copy of the catalog to keep in sync.
    private var store: BusCatalogStore { BusCatalogStore.shared }
    @State private var lineState: BusLineState?
    /// `ID_SENTIT` of the direction the `Anada`/`Tornada` chip selects: full
    /// opacity for its route and its buses, dimmed for the other one (spec S3).
    @State private var selectedDirectionID = 1
    @State private var showLinePicker = false
    /// Stop whose sheet is open (spec S6).
    @State private var selectedStop: BusStop?
    /// Camera bearing in degrees clockwise from north: the bus pills rotate
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

    init() {}

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                mapArea
            }
            .navigationTitle("Mapa")
            .navigationBarTitleDisplayMode(.inline)
            // Both loader tasks live on the always-visible container: the map
            // only renders once a line is selected and its state exists, so a
            // task attached there would never start.
            .task {
                guard let client = app.client else { return }
                await store.load(client: client)
            }
            .task(id: store.selectedLineCode) {
                guard let client = app.client, let line = store.selectedLine else { return }
                let state = BusLineState(line: line, client: client)
                self.lineState = state
                await state.run()
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
                BusStopSheet(stop: stop, line: line, incidents: incidents(for: stop, in: state, line: line))
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
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
                }
                IncidentsChip(busLineCode: String(line.code), lineDisplayName: line.name)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 16)
            .padding(.bottom, 8)
        }
    }

    // MARK: - Map

    @ViewBuilder
    private var mapArea: some View {
        if let message = app.missingCredentialsMessage {
            ConfigurationNotice(message: message)
        } else if let line = store.selectedLine, let state = lineState {
            lineMap(state: state, line: line)
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
            ProgressView("Carregant…")
        }
    }

    @ViewBuilder
    private func lineMap(state: BusLineState, line: BusLine) -> some View {
        Map(position: $cameraPosition) {
            ForEach(state.directions) { direction in
                // One polyline per direction: the selected one at full color,
                // the other at 40 % (spec S3). The opacity goes into the stroke
                // color because a map overlay has no view opacity to set.
                MapPolyline(coordinates: direction.route.points.map { point in
                    CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
                })
                .stroke(
                    Color(hex: line.colorHex).opacity(direction.id == selectedDirectionID ? 1 : 0.4),
                    style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round)
                )
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
            ForEach(state.positions) { position in
                // Empty title: the destination is already on the marker.
                Annotation("", coordinate: CLLocationCoordinate2D(latitude: position.train.position.latitude, longitude: position.train.position.longitude)) {
                    BusMarker(
                        lineName: line.name,
                        colorHex: line.colorHex,
                        textColorHex: line.textColorHex,
                        destination: position.train.destination,
                        rotation: position.train.heading - 90 - cameraHeading,
                        showLabel: latitudeSpan < Self.labelSpanThreshold,
                        opacity: position.directionID == selectedDirectionID ? 1 : 0.55
                    )
                }
            }
        }
        .mapStyle(.standard(elevation: .flat))
        .onMapCameraChange(frequency: .onEnd) { context in
            cameraHeading = context.camera.heading
            latitudeSpan = context.region.span.latitudeDelta
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
            // covers both the first load and a change of line.
            if !state.directions.isEmpty {
                fitCamera(to: state)
            }
        }
        .onAppear {
            if !state.directions.isEmpty {
                fitCamera(to: state)
            }
        }
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

    /// Fit the camera to the whole line on every change of line, so a long
    /// horizontal line is not cut off by the fixed Barcelona region.
    private func fitCamera(to state: BusLineState) {
        guard let region = Self.region(fitting: state.directions.flatMap { $0.route.points }) else { return }
        withAnimation(.easeInOut(duration: 0.35)) {
            cameraPosition = .region(region)
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

/// Moving bus marker: the line-colored pill with its name, a notch pointing
/// where the bus is heading, and the destination label when zoomed in (S3).
private struct BusMarker: View {
    let lineName: String
    let colorHex: String
    let textColorHex: String
    let destination: String
    /// Rotation of the pill: `heading - 90 - cameraHeading`, the same rule the
    /// east-facing metro pictograms use, so 0 degrees means heading east.
    let rotation: Double
    let showLabel: Bool
    /// 1 for the direction on screen, 0.55 for the other one (spec S3).
    let opacity: Double

    /// Width and height of the pill in points.
    private static let pillSize = CGSize(width: 34, height: 20)

    var body: some View {
        // MapKit centers an annotation on its coordinate, so only the pill and
        // its notch rotate and `rotationEffect` keeps the layout size at
        // 34x20 pt: the label lives in an overlay on that unrotated frame,
        // which adds nothing to the marker size and always stays upright.
        pill
            .rotationEffect(.degrees(rotation))
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
            .accessibilityLabel("Bus \(lineName) cap a \(destination)")
    }

    private var pill: some View {
        ZStack {
            Capsule()
                .fill(Color(hex: colorHex))
                .overlay(Capsule().stroke(.white, lineWidth: 2))
            Text(lineName)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color(hex: textColorHex))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.horizontal, 3)
        }
        .frame(width: Self.pillSize.width, height: Self.pillSize.height)
        .overlay(alignment: .trailing) {
            // The notch marks the front of the vehicle: the marker rotates so
            // that 0 degrees heads east, exactly like the metro pictograms.
            HeadingNotch()
                .fill(.white)
                .frame(width: 6, height: 8)
                .offset(x: 4)
        }
    }
}

/// Triangle pointing right, used as the heading notch of the bus pill.
private struct HeadingNotch: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
        }
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
