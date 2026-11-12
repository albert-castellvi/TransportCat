import CoreLocation
import SwiftUI
import UIKit

/// Explora tab (spec S12): search over places and lines, the favorites with
/// their next arrivals, and the places around the rider. Wired into `RootView`
/// as the fourth tab by the S8 worker; everything it needs is a shared store,
/// so it takes no arguments.
@MainActor
struct ExploreScreen: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.openURL) private var openURL
    @State private var query = ""
    /// Place whose detail sheet is open.
    @State private var selectedPlace: Place?
    /// Next arrivals of the favorite places, keyed by `Place.id`, refreshed on
    /// the screen's 30 s loop while it is visible.
    @State private var favoriteArrivals: [String: [FavoriteArrival]] = [:]
    /// Favorites whose arrivals feed failed on the last pass, so their rows
    /// do not claim that nothing is due (#97).
    @State private var failedFavoriteIDs: Set<String> = []
    /// Whether the first arrivals refresh has finished, so the rows can tell
    /// "loading" from "nothing expected here".
    @State private var arrivalsLoaded = false
    /// Generation of the arrivals refresh (spec S12): the 30 s loop and the
    /// star toggle both refresh, and only the newest pass may write, so the
    /// slower older one cannot replace fresh arrivals.
    @State private var arrivalsGeneration = ArrivalRefreshGeneration()
    /// The map mode that keeps `RootView`'s single FGC poller alive (spec S6).
    /// Under metro and bus that task is cancelled, so this screen refreshes the
    /// shared FGC snapshot itself (spec S12).
    @AppStorage("appMode") private var modeRaw = AppMode.metro.rawValue

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

    /// A failed first load with no cached copy leaves the search and "A prop"
    /// empty; their empty states would blame the rider's query or the radius,
    /// so the store's own error is shown instead (#66).
    private var catalogFailed: Bool {
        catalog.places.isEmpty && catalog.errorMessage != nil
    }

    @ViewBuilder
    private var catalogErrorSection: some View {
        if let message = catalog.errorMessage {
            Section {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Reintenta") {
                    guard let client = app.client else { return }
                    Task { await catalog.reload(client: client) }
                }
                .disabled(catalog.isLoading)
            }
        }
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
                if catalogFailed {
                    catalogErrorSection
                }
                if hasQuery, !catalogFailed {
                    searchResultsSections
                }
                favoritesSection
                if !catalogFailed {
                    nearbySection
                }
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
        // The Línies tab list needs FGC routes and the favorites read the
        // shared trains; the topology load is the same one-off the map does.
        if fgc.lines.isEmpty {
            await fgc.loadTopology()
        }
        LocationService.shared.start()

        while !Task.isCancelled {
            await refreshFGCSnapshotIfNeeded()
            await refreshFavoriteArrivals()
            do {
                try await Task.sleep(nanoseconds: Self.arrivalsRefreshIntervalNanoseconds)
            } catch {
                return
            }
        }
    }

    /// Keeps the FGC snapshot alive while the map's poller is not (spec S12):
    /// the RootView loop only runs under the FGC and global modes, so under
    /// metro and bus the 30 s refresh of the favorites re-read a list nothing
    /// updated. Same cadence as the feed, so a favorite's rows stay current
    /// instead of freezing on the last FGC-tab poll.
    @MainActor
    private func refreshFGCSnapshotIfNeeded() async {
        let mode = AppMode(rawValue: modeRaw) ?? .metro
        guard mode != .fgc, mode != .global, !fgc.lines.isEmpty else { return }
        await fgc.poll()
    }

    /// One refresh pass over the favorite places. A cancelled pass throws away
    /// its answer, and so does a pass a newer one has already replaced: only
    /// the newest generation writes the snapshot.
    @MainActor
    private func refreshFavoriteArrivals() async {
        let generation = arrivalsGeneration.begin()
        let places = favorites.favoritePlaces
        defer {
            if !Task.isCancelled, arrivalsGeneration.isCurrent(generation) {
                arrivalsLoaded = true
            }
        }
        guard !places.isEmpty else {
            favoriteArrivals = [:]
            failedFavoriteIDs = []
            return
        }
        guard let client = app.client else { return }
        let fetched = await ExploreArrivals.nextArrivals(
            for: places,
            client: client,
            fgcState: fgc,
            busLines: busStore.lines
        )
        guard !Task.isCancelled, arrivalsGeneration.isCurrent(generation) else { return }
        favoriteArrivals = fetched.arrivals
        failedFavoriteIDs = fetched.failedPlaceIDs
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
        Section {
            if favorites.favoritePlaces.isEmpty && favoriteLines.isEmpty {
                Text("Encara no tens preferits. Toca l'estrella d'una estació o parada.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(favorites.favoritePlaces) { place in
                favoritePlaceRow(place)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            FavoritesStore.shared.toggle(place)
                        } label: {
                            Label("Treu de preferits", systemImage: "star.slash")
                        }
                    }
            }
            .onMove { source, destination in
                FavoritesStore.shared.move(fromOffsets: source, toOffset: destination)
            }
            ForEach(favoriteLines) { result in
                ExploreLineRow(result: result)
            }
        } header: {
            HStack {
                Text("Preferits")
                Spacer()
                if favorites.favoritePlaces.count >= 2 {
                    EditButton()
                }
            }
        }
    }

    /// A favorite place with its next two arrivals (spec S12).
    @ViewBuilder
    private func favoritePlaceRow(_ place: Place) -> some View {
        let arrivals = favoriteArrivals[place.id] ?? []
        let modeLabel = modeLabel(for: place.kind)
        VStack(alignment: .leading, spacing: 6) {
            Button {
                selectedPlace = place
            } label: {
                // When arrivals are present, the line codes show in the
                // arrival rows; avoid printing the code twice. Pass the
                // mode word only as a standalone caption so the code is
                // never repeated.
                let caption = arrivals.isEmpty
                    ? (modeLabel.isEmpty ? nil : "\(modeLabel) \(place.lineCodes.joined(separator: " · "))")
                    : ""
                ExplorePlaceRow(place: place, caption: caption.isEmpty ? nil : caption)
            }
            .buttonStyle(.plain)
            if arrivals.isEmpty {
                Text(emptyArrivalsText(for: place))
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

    /// A feed that failed is not the same as a stop with nothing due (#97).
    private func emptyArrivalsText(for place: Place) -> String {
        guard arrivalsLoaded else { return "Carregant arribades…" }
        return failedFavoriteIDs.contains(place.id)
            ? "No s'han pogut carregar les arribades."
            : NearbyStops.emptyArrivalText(
                isBusStop: place.kind == .busStop,
                lineCodes: place.lineCodes,
                busDirections: nil
            )
    }

    /// Mode word for a place: "Metro", "Bus", or "FGC". Empty for unknown
    /// kinds so the caller can gate the caption.
    private func modeLabel(for kind: PlaceKind) -> String {
        switch kind {
        case .metroStation: return "Metro"
        case .busStop: return "Bus"
        case .fgcStation: return "FGC"
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
                VStack(alignment: .leading, spacing: 6) {
                    Text("Activa la ubicació a Configuració per veure què tens a prop.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Obre Configuració", action: openSettings)
                        .font(.footnote)
                }
            } else {
                // The same list the "A prop teu" sheet and the Tot screen host
                // (spec S10/S13); tapping opens Explora's own detail sheet
                // instead of the router hand-off the sheet uses.
                NearbyStopsList { place in
                    selectedPlace = place
                }
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
        }
    }

    /// Opens the app's Settings page so a denied location permission can be
    /// turned back on without leaving the app (#98).
    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }
}
