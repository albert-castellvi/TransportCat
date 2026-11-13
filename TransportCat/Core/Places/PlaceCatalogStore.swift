import Foundation
import Observation

/// The whole place catalog: every metro station, every TMB bus stop, every FGC
/// station and every Rodalies station, loaded once per launch and persisted
/// with `DiskCache` (spec S2, S3).
///
/// The screens only ever read `places`; loading is explicit so the app decides
/// when to spend the TMB quota. A failed load falls back to the cached copy, so
/// a warm launch keeps the search and the nearby list working offline.
@MainActor
@Observable
final class PlaceCatalogStore {
    static let shared = PlaceCatalogStore()

    /// Versioned cache key. A model change must use a new key.
    static let cacheKey = "places.v1"

    private(set) var places: [Place] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    /// When the in-memory catalog was last replaced by a successful load.
    private(set) var loadedAt: Date?

    private let cache: DiskCache
    /// One load per launch: an empty `places` from the cache still triggers the
    /// network refresh, but a successful attempt does not repeat. An attempt
    /// that ends with an empty catalog clears the guard, so a failed first load
    /// never locks the whole launch (#66).
    private var hasAttemptedLoad = false

    init(cache: DiskCache = .shared) {
        self.cache = cache
    }

    // MARK: - Filters

    var metroPlaces: [Place] { places.filter { $0.kind == .metroStation } }
    var busPlaces: [Place] { places.filter { $0.kind == .busStop } }
    var fgcPlaces: [Place] { places.filter { $0.kind == .fgcStation } }
    var rodaliesPlaces: [Place] { places.filter { $0.kind == .rodaliesStation } }

    func place(id: String) -> Place? {
        places.first { $0.id == id }
    }

    // MARK: - Loading

    /// Loads the four networks in parallel. A second call returns at once,
    /// keeping the catalog already on screen.
    ///
    /// The Rodalies stations come from the topology bundled with the app, so
    /// they cost no request; the parameter exists so the caller (or a test) can
    /// supply a different topology, and an empty list simply keeps them out of
    /// the catalog.
    ///
    /// - Returns: whether the catalog ended up usable (fresh or cached).
    @discardableResult
    func load(
        client: TMBClient,
        fgcClient: FGCClient = FGCClient(),
        rodaliesStations: [RodaliesStation] = RodaliesTopology.bundled?.stations ?? []
    ) async -> Bool {
        guard !hasAttemptedLoad, !isLoading else { return !places.isEmpty }
        hasAttemptedLoad = true
        isLoading = true
        defer {
            isLoading = false
            // #66: a failed load without a cached copy leaves the catalog empty.
            // Clearing the guard here lets the next screen's load try again
            // instead of answering an empty catalog for the rest of the launch.
            if places.isEmpty { hasAttemptedLoad = false }
        }

        do {
            async let metroLines = client.metroPlaceLines()
            async let busStops = client.busNetworkStops()
            async let busLines = client.busLines()
            async let fgcStations = fgcClient.stations()
            async let fgcRoutes = fgcClient.routes()
            async let fgcStops = fgcClient.allStops()

            let (loadedMetro, loadedBusStops, loadedBusLines, loadedFGCStations, loadedFGCRoutes, loadedFGCStops) =
                try await (metroLines, busStops, busLines, fgcStations, fgcRoutes, fgcStops)

            let busLineStops = try await client.busPlaceLines(loadedBusLines)
            let fgcTopology = FGCNetwork.stations(
                loadedFGCStations,
                points: FGCNetwork.stopIndex(loadedFGCStops)
            )

            let loaded = TMBPlaceParser.metroPlaces(from: loadedMetro)
                + TMBPlaceParser.busPlaces(stops: loadedBusStops, lines: busLineStops)
                + TMBPlaceParser.fgcPlaces(stations: fgcTopology, lines: loadedFGCRoutes)
                + TMBPlaceParser.rodaliesPlaces(stations: rodaliesStations)

            guard !loaded.isEmpty else { throw PlaceCatalogError.empty }
            places = loaded.sorted(by: placeOrder)
            loadedAt = Date()
            errorMessage = nil
            cache.save(places, forKey: Self.cacheKey)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return loadFromCache()
        }
    }

    /// Clears the launch guard so a retry button can load again.
    @discardableResult
    func reload(
        client: TMBClient,
        fgcClient: FGCClient = FGCClient(),
        rodaliesStations: [RodaliesStation] = RodaliesTopology.bundled?.stations ?? []
    ) async -> Bool {
        hasAttemptedLoad = false
        return await load(
            client: client,
            fgcClient: fgcClient,
            rodaliesStations: rodaliesStations
        )
    }

    /// Reads the cached catalog, if any, without touching the network. Also
    /// used as the fallback of a failed load.
    @discardableResult
    func loadFromCache() -> Bool {
        guard let cached = cache.load([Place].self, forKey: Self.cacheKey), !cached.isEmpty else {
            return false
        }
        places = cached
        loadedAt = cache.savedAt(forKey: Self.cacheKey)
        return true
    }

    // MARK: - Ordering

    /// Alphabetical by folded name, then id. Same rule as the parsers, so the
    /// persisted and the freshly loaded catalog have the same order.
    private func placeOrder(_ lhs: Place, _ rhs: Place) -> Bool {
        let left = PlaceIndex.normalized(lhs.name)
        let right = PlaceIndex.normalized(rhs.name)
        if left != right { return left < right }
        return lhs.id < rhs.id
    }
}

/// Why a load produced no place at all.
enum PlaceCatalogError: LocalizedError {
    case empty

    var errorDescription: String? {
        switch self {
        case .empty:
            return String(localized: "El catàleg de llocs ha arribat buit.")
        }
    }
}
