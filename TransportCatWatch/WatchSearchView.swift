import SwiftUI

/// Search by name over the synced favorites and the place catalog (spec S22).
///
/// `PlaceIndex.search` is the shared ranking (S1). The catalog is the same
/// extension-safe `PlaceCatalogStore` the widget reuses: cached first, then
/// one network load so the watch can search places that are not favorites.
@MainActor
struct WatchSearchView: View {
    @Environment(WatchFavoritesStore.self) private var favorites

    @State private var query = ""
    @State private var isCatalogLoading = false

    var body: some View {
        List {
            if query.isEmpty {
                Text("Escriu un nom per cercar")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if results.isEmpty {
                Text("Cap resultat")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(results) { place in
                    NavigationLink {
                        WatchPlaceDetailView(place: place)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(place.name)
                                .font(.headline)
                                .lineLimit(1)
                            Text(kindLabel(place.kind))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if isCatalogLoading {
                HStack(spacing: 6) {
                    ProgressView()
                    Text("Carregant el catàleg…")
                        .font(.caption2)
                }
            }
        }
        .navigationTitle("Cerca")
        .searchable(text: $query, prompt: "Cerca estacions o parades")
        .task { await loadCatalog() }
    }

    private var results: [Place] {
        PlaceIndex.search(query: query, places: searchablePlaces, limit: 20)
    }

    /// The synced favorites plus the catalog, one entry per place id.
    private var searchablePlaces: [Place] {
        var seen = Set<String>()
        return (favorites.places + PlaceCatalogStore.shared.places)
            .filter { seen.insert($0.id).inserted }
    }

    /// Cached catalog first (works offline), then one network load.
    private func loadCatalog() async {
        let catalog = PlaceCatalogStore.shared
        catalog.loadFromCache()
        guard catalog.places.isEmpty, let client = WatchServices.tmbClient() else { return }
        isCatalogLoading = true
        defer { isCatalogLoading = false }
        await catalog.load(client: client)
    }

    private func kindLabel(_ kind: PlaceKind) -> String {
        switch kind {
        case .metroStation: return "Metro"
        case .busStop: return "Bus"
        case .fgcStation: return "FGC"
        }
    }
}
