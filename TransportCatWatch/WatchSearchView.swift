import SwiftUI

/// Search by name over the synced favorites and the place catalog (spec S22,
/// reviews W9, W10, W15).
///
/// `PlaceIndex.search` is the shared ranking (S1). The catalog is the same
/// extension-safe `PlaceCatalogStore` the widget reuses: cached first, then one
/// network load so the watch can search places that are not favorites.
///
/// Typing here costs a dictation or a scribble, so the last queries that led
/// somewhere come back as one-tap rows, and a failed catalog says so instead of
/// pretending the place does not exist.
@MainActor
struct WatchSearchView: View {
    @Environment(WatchFavoritesStore.self) private var favorites

    @State private var query = ""
    @State private var isCatalogLoading = false
    /// Whether a catalog load has finished without filling the catalog. The
    /// store's own `errorMessage` is not shown: it is a system message in the
    /// system language, and this screen speaks Catalan.
    @State private var catalogUnavailable = false
    @State private var recent: [String] = []
    @State private var recording: Task<Void, Never>?

    private var catalog: PlaceCatalogStore { .shared }

    var body: some View {
        List {
            if query.isEmpty {
                recentRows
                Text("Digues o escriu un lloc")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if results.isEmpty && !isCatalogLoading {
                Text("Cap resultat. Prova amb un altre nom.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                resultRows
            }
            if isCatalogLoading {
                HStack(spacing: 6) {
                    ProgressView()
                    Text("Carregant…")
                        .font(.caption2)
                }
            }
            if catalogUnavailable && !isCatalogLoading {
                failureRow
            }
        }
        .navigationTitle("Cerca")
        .searchable(text: $query, prompt: "Cerca estacions o parades")
        .task {
            recent = WatchRecentSearches.read()
            await loadCatalog()
        }
        .onChange(of: query) { _, newValue in record(newValue) }
    }

    // MARK: - Rows

    @ViewBuilder
    private var recentRows: some View {
        ForEach(recent, id: \.self) { entry in
            Button {
                query = entry
            } label: {
                Label(entry, systemImage: "clock")
            }
        }
    }

    @ViewBuilder
    private var resultRows: some View {
        ForEach(results) { place in
            NavigationLink {
                WatchPlaceDetailView(place: place)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(place.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text(subtitle(place))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Review W10: a catalog that failed says so, and offers the retry the
    /// system has no way to offer.
    private var failureRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No s'ha pogut carregar el catàleg.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("Torna-ho a provar") {
                Task { await reloadCatalog() }
            }
        }
    }

    // MARK: - Data

    private var results: [Place] {
        PlaceIndex.search(query: query, places: searchablePlaces, limit: 20)
    }

    /// The synced favorites plus the catalog, one entry per place id.
    private var searchablePlaces: [Place] {
        var seen = Set<String>()
        return (favorites.places + catalog.places)
            .filter { seen.insert($0.id).inserted }
    }

    /// Cached catalog first (works offline), then one network load.
    private func loadCatalog() async {
        catalog.loadFromCache()
        guard catalog.places.isEmpty else {
            catalogUnavailable = false
            return
        }
        guard let client = WatchServices.tmbClient() else {
            // A build without credentials can never fill the catalog, and the
            // rider deserves to hear it instead of "cap resultat".
            catalogUnavailable = true
            return
        }
        isCatalogLoading = true
        defer { isCatalogLoading = false }
        await catalog.load(client: client)
        catalogUnavailable = catalog.places.isEmpty
    }

    /// The retry of `failureRow`. `reload` clears the store's once-per-launch
    /// guard, so a catalog that failed at launch can still be fetched.
    private func reloadCatalog() async {
        guard let client = WatchServices.tmbClient() else {
            catalogUnavailable = true
            return
        }
        isCatalogLoading = true
        defer { isCatalogLoading = false }
        await catalog.reload(client: client)
        catalogUnavailable = catalog.places.isEmpty
    }

    /// Remembers a query that found something (review W9).
    ///
    /// Debounced: dictation and scribble land the whole text at once, but a
    /// typed word would otherwise store every prefix of it.
    private func record(_ text: String) {
        recording?.cancel()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        recording = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled, !results.isEmpty else { return }
            recent = WatchRecentSearches.record(text)
        }
    }

    /// Review W10: the kind alone cannot tell two places of the same name
    /// apart, and the line codes are what the rider recognises.
    private func subtitle(_ place: Place) -> String {
        let lines = place.lineCodes.prefix(3).joined(separator: " ")
        return lines.isEmpty ? kindLabel(place.kind) : "\(kindLabel(place.kind)) · \(lines)"
    }

    private func kindLabel(_ kind: PlaceKind) -> String {
        switch kind {
        case .metroStation: return String(localized: "Metro")
        case .busStop: return String(localized: "Bus")
        case .fgcStation: return String(localized: "FGC")
        case .rodaliesStation: return String(localized: "Rodalies")
        }
    }
}
