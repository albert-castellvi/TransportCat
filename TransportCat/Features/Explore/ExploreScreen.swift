import CoreLocation
import SwiftUI

/// Explora tab (spec S12): search over places and lines, the favorites with
/// their next arrivals, and the places around the rider. Wired into `RootView`
/// as the fourth tab by the S8 worker; everything it needs is a shared store,
/// so it takes no arguments.
@MainActor
struct ExploreScreen: View {
    @EnvironmentObject private var app: AppModel
    @State private var query = ""
    /// Place whose detail sheet is open.
    @State private var selectedPlace: Place?
    /// Next arrivals of the favorite places, keyed by `Place.id`, refreshed on
    /// the screen's 30 s loop while it is visible.
    @State private var favoriteArrivals: [String: [FavoriteArrival]] = [:]
    /// Whether the first arrivals refresh has finished, so the rows can tell
    /// "loading" from "nothing expected here".
    @State private var arrivalsLoaded = false

    /// Refresh period of the favorites' arrivals (spec S12), in nanoseconds.
    private static let arrivalsRefreshIntervalNanoseconds: UInt64 = 30_000_000_000

    init() {}

    private var catalog: PlaceCatalogStore { PlaceCatalogStore.shared }
    private var favorites: FavoritesStore { FavoritesStore.shared }
    private var busStore: BusCatalogStore { BusCatalogStore.shared }
    private var fgc: FGCNetworkState { FGCNetworkState.shared }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasQuery: Bool {
        !trimmedQuery.isEmpty
    }

    var body: some View {
        NavigationStack {
            List {
                // Planner entry (spec S16): the only row Explora adds for it.
                Section {
                    NavigationLink {
                        PlannerScreen()
                    } label: {
                        Label(
                            "Planifica un viatge",
                            systemImage: "point.topleft.down.to.point.bottomright.curvepath"
                        )
                    }
                }
                if hasQuery {
                    searchResultsSections
                }
                favoritesSection
                nearbySection
            }
            .navigationTitle("Explora")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Cerca estacions, parades o línies")
        }
        // The same presentation contract the maps use: detents declared at the
        // sheet site, never inside the presented view.
        .sheet(item: $selectedPlace) { place in
            ExplorePlaceDetailSheet(place: place)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .task {
            await bootstrapAndRefresh()
        }
        // Location updates start and stop with the screen (spec S12); the last
        // known point stays available in the service.
        .onDisappear {
            LocationService.shared.stop()
        }
        .onChange(of: favorites.favoritePlaces.count) { _, _ in
            Task { await refreshFavoriteArrivals() }
        }
    }

    // MARK: - Life cycle

    /// Loads the catalogs this screen reads (each store is idempotent per
    /// launch), starts location updates and keeps the favorites' arrivals
    /// fresh while the tab is visible.
    @MainActor
    private func bootstrapAndRefresh() async {
        if let client = app.client {
            if catalog.places.isEmpty {
                _ = await catalog.load(client: client)
            }
            await busStore.load(client: client)
        }
        // The Línies tab list needs FGC routes and this screen only reads the
        // shared state; the topology load is the same one-off the map does.
        if fgc.lines.isEmpty {
            await fgc.loadTopology()
        }
        LocationService.shared.start()

        while !Task.isCancelled {
            await refreshFavoriteArrivals()
            do {
                try await Task.sleep(nanoseconds: Self.arrivalsRefreshIntervalNanoseconds)
            } catch {
                return
            }
        }
    }

    /// One refresh pass over the favorite places. A cancelled pass throws away
    /// its answer instead of racing the next one.
    @MainActor
    private func refreshFavoriteArrivals() async {
        let places = favorites.favoritePlaces
        defer { if !Task.isCancelled { arrivalsLoaded = true } }
        guard !places.isEmpty else {
            favoriteArrivals = [:]
            return
        }
        guard let client = app.client else { return }
        let loaded = await ExploreArrivals.nextArrivals(
            for: places,
            client: client,
            fgcState: fgc,
            busLines: busStore.lines
        )
        guard !Task.isCancelled else { return }
        favoriteArrivals = loaded
    }

    // MARK: - Search results

    @ViewBuilder
    private var searchResultsSections: some View {
        let places = PlaceIndex.search(query: trimmedQuery, places: catalog.places)
        let lines = searchedLines
        if !places.isEmpty {
            Section("Estacions i parades") {
                ForEach(places) { place in
                    Button {
                        selectedPlace = place
                    } label: {
                        ExplorePlaceRow(place: place)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        if !lines.isEmpty {
            Section("Línies") {
                ForEach(lines) { result in
                    ExploreLineRow(result: result)
                }
            }
        }
        if places.isEmpty && lines.isEmpty {
            Section {
                ContentUnavailableView(
                    "Cap resultat",
                    systemImage: "magnifyingglass",
                    description: Text("Prova-ho amb un altre nom d'estació, parada o línia.")
                )
                .listRowBackground(Color.clear)
            }
        }
    }

    /// Metro, FGC and bus lines folded-ranked over the query; bus rows reuse
    /// `BusCatalog.search`, which also matches description, origin and
    /// destination, and inherit their catalog rank when the name alone misses.
    private var searchedLines: [ExploreLineResult] {
        var results: [ExploreLineResult] = []
        for line in MetroLine.allLines {
            if let rank = ExploreFormatting.bestLineRank(fields: [line.displayName, line.code], query: trimmedQuery) {
                results.append(ExploreLineResult(kind: .metro(line), rank: rank))
            }
        }
        for line in fgc.lines {
            if let rank = ExploreFormatting.bestLineRank(fields: [line.code, line.name], query: trimmedQuery) {
                results.append(ExploreLineResult(kind: .fgc(line), rank: rank))
            }
        }
        for line in BusCatalog.search(busStore.lines, query: trimmedQuery) {
            let rank = ExploreFormatting.bestLineRank(fields: [line.name, String(line.code)], query: trimmedQuery) ?? 3
            results.append(ExploreLineResult(kind: .bus(line), rank: rank))
        }
        return results.sorted { lhs, rhs in
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            return lhs.label.localizedStandardCompare(rhs.label) == .orderedAscending
        }
    }

    // MARK: - Preferits

    @ViewBuilder
    private var favoritesSection: some View {
        let favoriteLines = favoriteLineResults
        Section("Preferits") {
            if favorites.favoritePlaces.isEmpty && favoriteLines.isEmpty {
                Text("Encara no tens preferits. Toca l'estrella d'una estació o parada.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(favorites.favoritePlaces) { place in
                favoritePlaceRow(place)
            }
            ForEach(favoriteLines) { result in
                ExploreLineRow(result: result)
            }
        }
    }

    /// A favorite place with its next two arrivals (spec S12).
    @ViewBuilder
    private func favoritePlaceRow(_ place: Place) -> some View {
        let arrivals = favoriteArrivals[place.id] ?? []
        VStack(alignment: .leading, spacing: 6) {
            Button {
                selectedPlace = place
            } label: {
                ExplorePlaceRow(place: place)
            }
            .buttonStyle(.plain)
            if arrivals.isEmpty {
                Text(arrivalsLoaded ? "Sense arribades ara mateix." : "Carregant arribades…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            } else {
                ForEach(arrivals) { arrival in
                    ExploreFavoriteArrivalRow(arrival: arrival)
                }
            }
        }
        .contextMenu {
            Button {
                FavoritesStore.shared.toggle(place)
            } label: {
                Label("Treu de preferits", systemImage: "star.slash")
            }
        }
    }

    /// Favorite metro/FGC lines from `FavoritesStore` plus the catalog's own
    /// bus favorites (spec S4 keeps them separate). Lines the catalogs have
    /// not loaded yet appear once their operator's data arrives.
    private var favoriteLineResults: [ExploreLineResult] {
        var results: [ExploreLineResult] = []
        for line in favorites.favoriteLines {
            switch line.operator {
            case FavoriteLine.metro:
                if let metro = MetroLine.line(forCode: line.code) {
                    results.append(ExploreLineResult(kind: .metro(metro), rank: 0))
                }
            case FavoriteLine.fgc:
                if let fgcLine = fgc.lines.first(where: { $0.code == line.code }) {
                    results.append(ExploreLineResult(kind: .fgc(fgcLine), rank: 0))
                }
            default:
                break
            }
        }
        for code in busStore.favorites {
            if let busLine = busStore.lines.first(where: { $0.code == code }) {
                results.append(ExploreLineResult(kind: .bus(busLine), rank: 0))
            }
        }
        return results
    }

    // MARK: - A prop

    @ViewBuilder
    private var nearbySection: some View {
        let service = LocationService.shared
        Section("A prop") {
            if service.authorization == .notDetermined {
                Button("Activa la ubicació") {
                    service.requestWhenInUse()
                }
            } else if service.authorization == .denied || service.authorization == .restricted {
                Text("Activa la ubicació a Configuració per veure què tens a prop.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if let position = service.location {
                nearbyRows(position: position)
            } else {
                ProgressView("Cercant la teva ubicació…")
            }
        }
    }

    /// The ten nearest places within one kilometer (spec S12), with distance
    /// and walking minutes in the caption.
    @ViewBuilder
    private func nearbyRows(position: GeoPoint) -> some View {
        let found = PlaceIndex.nearest(
            to: position,
            places: catalog.places,
            limit: ExploreFormatting.nearbyLimit,
            maxDistance: ExploreFormatting.nearbyRadiusMeters
        )
        if found.isEmpty {
            Text("No tens cap estació ni parada a menys d'un quilòmetre.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        ForEach(found) { item in
            Button {
                selectedPlace = item.place
            } label: {
                ExplorePlaceRow(
                    place: item.place,
                    caption: ExploreFormatting.nearbyCaption(meters: item.distance)
                )
            }
            .buttonStyle(.plain)
        }
    }
}
