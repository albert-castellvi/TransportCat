import SwiftUI

/// Trip planner (spec S16): origin, destination, time and the list of
/// itineraries the TMB planner returns. Pushed from Explora's
/// "Planifica un viatge" row.
@MainActor
struct PlannerScreen: View {
    @EnvironmentObject private var app: AppModel

    @State private var origin: PlannerEndpoint?
    @State private var destination: PlannerEndpoint?
    @State private var timeMode: PlannerTimeMode = .departNow
    /// The date the "Surt a les…"/"Arriba a les…" pickers write; "Surt ara"
    /// ignores it and plans from the current instant.
    @State private var plannedDate = Date()
    @State private var itineraries: [Itinerary] = []
    @State private var isPlanning = false
    @State private var errorMessage: String?
    /// Which endpoint the place picker sheet is editing.
    @State private var picking: PlannerPickerTarget?

    /// Read in `body`, so a fix that lands after the push re-evaluates the
    /// origin default below.
    private var location: LocationService { LocationService.shared }

    init() {}

    var body: some View {
        List {
            routeSection
            timeSection
            searchNoticeSection
            searchSection
            resultsSection
        }
        .navigationTitle("Planifica un viatge")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: Itinerary.self) { itinerary in
            PlannerItineraryDetail(itinerary: itinerary)
        }
        .sheet(item: $picking) { target in
            PlannerPlacePickerSheet(
                title: target.sheetTitle,
                allowsCurrentLocation: target.allowsCurrentLocation
            ) { endpoint in
                let (newOrigin, newDestination) = applyPlannerPick(
                    endpoint,
                    to: target,
                    origin: origin,
                    destination: destination
                )
                origin = newOrigin
                destination = newDestination
            }
        }
        .task {
            // The origin default: a fix is offered as "La meva ubicació" as
            // soon as the service has one (spec S16). The first fix usually
            // lands after this task, so `onChange` below takes it too.
            location.start()
            adoptCurrentLocation()
        }
        .onChange(of: location.location) { _, _ in
            adoptCurrentLocation()
        }
    }

    /// Uses the first fix as the origin while the rider has not picked one
    /// (spec S16). Re-run on every fix: on a cold start, or after Explora
    /// stopped the service on its way out, `currentLocation()` is still nil
    /// when the screen appears. Does not overwrite an origin the rider
    /// cleared by choosing the current location as destination instead.
    private func adoptCurrentLocation() {
        guard origin == nil, destination?.isCurrentLocation != true,
              let current = PlannerEndpoint.currentLocation()
        else { return }
        origin = current
    }

    // MARK: - Sections

    private var routeSection: some View {
        Section {
            endpointRow(
                for: .origin,
                icon: "circle.fill",
                iconColor: .green,
                endpoint: origin,
                placeholder: "Afegeix un origen"
            )
            endpointRow(
                for: .destination,
                icon: "mappin",
                iconColor: .red,
                endpoint: destination,
                placeholder: "Afegeix una destinació"
            )
            Button {
                swapEndpoints()
            } label: {
                Label("Intercanvia l'origen i la destinació", systemImage: "arrow.up.arrow.down")
                    .font(.footnote)
            }
            .disabled(origin == nil && destination == nil)
        }
    }

    /// Swaps the two endpoints, so the rider does not have to pick both again
    /// just to plan the return trip (#96).
    private func swapEndpoints() {
        let previousOrigin = origin
        origin = destination
        destination = previousOrigin
    }

    /// One tappable origin/destination row opening the place picker.
    private func endpointRow(
        for target: PlannerPickerTarget,
        icon: String,
        iconColor: Color,
        endpoint: PlannerEndpoint?,
        placeholder: String
    ) -> some View {
        Button {
            picking = target
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .foregroundStyle(iconColor)
                Text(endpoint?.label ?? placeholder)
                    .foregroundStyle(endpoint == nil ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if let detail = endpoint?.detailLabel {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityLabel(target.sheetTitle)
            .accessibilityValue(endpoint?.label ?? placeholder)
        }
    }

    private var timeSection: some View {
        Section {
            Picker("Quan", selection: $timeMode) {
                ForEach(PlannerTimeMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.menu)
            if timeMode.needsDatePicker {
                DatePicker(
                    timeMode.label,
                    selection: $plannedDate,
                    displayedComponents: [.date, .hourAndMinute]
                )
            }
        }
    }

    /// The search button is disabled while the build has no TMB credentials,
    /// so the same notice the maps show names the reason here instead of
    /// leaving a dead button (UX-19).
    @ViewBuilder
    private var searchNoticeSection: some View {
        if let message = app.missingCredentialsMessage {
            Section {
                ConfigurationNotice(message: message)
                    .listRowBackground(Color.clear)
            }
        }
    }

    /// Primary search action: a filled button instead of a plain list row (#96).
    private var searchSection: some View {
        Section {
            Button {
                Task { await plan() }
            } label: {
                HStack(spacing: 8) {
                    Spacer()
                    if isPlanning {
                        ProgressView().controlSize(.small)
                    }
                    Text("Cerca")
                        .font(.headline.weight(.semibold))
                    Spacer()
                }
                .frame(maxWidth: .infinity, minHeight: 30)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canSearch || isPlanning)
        }
    }

    @ViewBuilder
    private var resultsSection: some View {
        if let errorMessage {
            Section {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }
        }
        if !itineraries.isEmpty {
            Section("Rutes") {
                ForEach(Array(itineraries.enumerated()), id: \.offset) { _, itinerary in
                    NavigationLink(value: itinerary) {
                        PlannerItineraryRow(itinerary: itinerary)
                    }
                }
            }
        } else if isPlanning {
            Section {
                ProgressView("Calculant la ruta…")
            }
        }
    }

    private var canSearch: Bool {
        origin != nil && destination != nil && app.client != nil
    }

    // MARK: - Search

    @MainActor
    private func plan() async {
        guard let origin, let destination, let client = app.client else { return }
        errorMessage = nil
        itineraries = []
        isPlanning = true
        defer { isPlanning = false }

        let date = timeMode == .departNow ? Date() : plannedDate
        do {
            let found = try await client.plan(
                from: origin.position,
                to: destination.position,
                date: date,
                arriveBy: timeMode.arriveBy
            )
            guard !Task.isCancelled else { return }
            itineraries = found
        } catch {
            guard !Task.isCancelled else { return }
            // Spec S16 words the two outcomes; anything else is a failure.
            errorMessage = (error as? PlannerError) == .noRoute
                ? "No s'ha trobat cap ruta."
                : "No s'ha pogut calcular la ruta. Torna-ho a provar."
        }
    }
}

// MARK: - Supporting types

/// One end of the planned trip: either the rider's live position or a place
/// chosen from the catalog.
struct PlannerEndpoint: Hashable {
    let label: String
    /// Caption under the label ("Metro · L1 · L3" for places).
    let detailLabel: String?
    let position: GeoPoint
    let isCurrentLocation: Bool

    init(label: String, detailLabel: String? = nil, position: GeoPoint, isCurrentLocation: Bool = false) {
        self.label = label
        self.detailLabel = detailLabel
        self.position = position
        self.isCurrentLocation = isCurrentLocation
    }

    init(place: Place) {
        self.init(
            label: place.name,
            detailLabel: place.lineCodes.isEmpty ? nil : place.lineCodes.joined(separator: " · "),
            position: place.position
        )
    }

    /// "La meva ubicació" once the location service has a fix.
    @MainActor
    static func currentLocation() -> PlannerEndpoint? {
        guard let point = LocationService.shared.location else { return nil }
        return PlannerEndpoint(label: "La meva ubicació", position: point, isCurrentLocation: true)
    }
}

/// Departure/arrival choice (spec S16).
enum PlannerTimeMode: String, CaseIterable, Identifiable {
    case departNow
    case departAt
    case arriveAt

    var id: String { rawValue }

    var label: String {
        switch self {
        case .departNow: return "Surt ara"
        case .departAt: return "Surt a les…"
        case .arriveAt: return "Arriba a les…"
        }
    }

    var needsDatePicker: Bool { self != .departNow }
    var arriveBy: Bool { self == .arriveAt }
}

/// Which endpoint the place picker sheet is editing.
enum PlannerPickerTarget: String, Identifiable {
    case origin
    case destination

    var id: String { rawValue }
    var sheetTitle: String { self == .origin ? "Origen" : "Destinació" }
    var allowsCurrentLocation: Bool { true }
}
