import SwiftUI

/// Trip planner (spec S16): origin, destination, time and the list of
/// itineraries the TMB planner returns. Pushed from Explora's
/// "Planifica un viatge" row.
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

    init() {}

    var body: some View {
        List {
            routeSection
            timeSection
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
                switch target {
                case .origin: origin = endpoint
                case .destination: destination = endpoint
                }
            }
        }
        .task {
            // The origin default: a fix is offered as "La meva ubicació" as
            // soon as the service has one (spec S16).
            LocationService.shared.start()
            if origin == nil, let current = PlannerEndpoint.currentLocation() {
                origin = current
            }
        }
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
        }
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
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let detail = endpoint?.detailLabel {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
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

    private var searchSection: some View {
        Section {
            Button {
                Task { await plan() }
            } label: {
                HStack {
                    Spacer()
                    if isPlanning {
                        ProgressView().controlSize(.small)
                    }
                    Text("Cerca")
                        .fontWeight(.semibold)
                    Spacer()
                }
            }
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
    var allowsCurrentLocation: Bool { self == .origin }
}
