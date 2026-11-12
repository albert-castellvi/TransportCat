import CoreLocation
import SwiftUI
import UIKit

/// Searchable place sheet shared by the planner's origin and destination rows
/// (spec S16). The origin version also offers "La meva ubicació", enabled as
/// soon as `LocationService` has a fix.
struct PlannerPlacePickerSheet: View {
    let title: String
    var allowsCurrentLocation = false
    let onSelect: (PlannerEndpoint) -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var app: AppModel
    @Environment(\.openURL) private var openURL
    @State private var query = ""

    private var catalog: PlaceCatalogStore { PlaceCatalogStore.shared }
    private var location: LocationService { LocationService.shared }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            List {
                if allowsCurrentLocation {
                    currentLocationSection
                }
                resultsSection
            }
            .searchable(text: $query, prompt: "Cerca estacions o parades")
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel·la") { dismiss() }
                }
            }
        }
        .task {
            // The Explora bootstrap usually got here first; this keeps the
            // sheet honest when the planner is reached before the catalog.
            if let client = app.client, catalog.places.isEmpty {
                _ = await catalog.load(client: client)
            }
            location.start()
        }
    }

    // MARK: - La meva ubicació

    @ViewBuilder
    private var currentLocationSection: some View {
        if let endpoint = PlannerEndpoint.currentLocation() {
            Button {
                onSelect(endpoint)
                dismiss()
            } label: {
                Label("La meva ubicació", systemImage: "location.fill")
            }
        } else if location.authorization == .notDetermined {
            Button {
                location.requestWhenInUse()
            } label: {
                Label("Activa la ubicació", systemImage: "location.circle")
            }
        } else if location.authorization == .denied || location.authorization == .restricted {
            VStack(alignment: .leading, spacing: 6) {
                Text("Activa la ubicació a Configuració per sortir de la teva posició.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Obre Configuració", action: openSettings)
                    .font(.footnote)
            }
        } else {
            // Authorized but still searching: the row waits for the first fix.
            Label("Cercant la teva ubicació…", systemImage: "location")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Results

    @ViewBuilder
    private var resultsSection: some View {
        let places = PlaceIndex.search(query: trimmedQuery, places: catalog.places, limit: 30)
        Section {
            if trimmedQuery.isEmpty {
                Text("Escriu el nom d'una estació o parada.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if places.isEmpty {
                Text("Cap resultat. Prova-ho amb un altre nom.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(places) { place in
                Button {
                    onSelect(PlannerEndpoint(place: place))
                    dismiss()
                } label: {
                    ExplorePlaceRow(place: place)
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text("Estacions i parades")
        }
    }

    /// Opens the app's Settings page so a denied location permission can be
    /// turned back on without leaving the app (#98).
    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }
}
