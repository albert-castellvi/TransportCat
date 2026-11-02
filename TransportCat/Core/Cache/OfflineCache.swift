import Foundation

/// Persistence of the topology catalogs for the offline mode (spec S21), on
/// top of `DiskCache` (S3).
///
/// Every store saves its snapshot here after a successful network load and
/// asks here for the cached copy when the next load fails, so a warm app
/// keeps drawing lines, stops and stations without a connection. All calls
/// are silent on failure, exactly like `DiskCache`: the offline copy is an
/// optimization, never a source of errors.
enum OfflineCache {
    // MARK: Keys (fixed by the spec: metro-topology-<code>, bus-catalog,
    // bus-topology-<code>, fgc-topology)

    /// Metro topology of one line, keyed by the TMB numeric line code ("1", "94").
    static func metroTopologyKey(lineCode: String) -> String {
        "metro-topology-\(lineCode)"
    }

    /// The whole bus line catalog (`/transit/linies/bus`).
    static let busCatalogKey = "bus-catalog"

    /// Stops and routes of one bus line, keyed by its numeric code (212).
    static func busTopologyKey(lineCode: Int) -> String {
        "bus-topology-\(lineCode)"
    }

    /// The merged FGC network (routes, colours, stations with coordinates).
    static let fgcTopologyKey = "fgc-topology"

    // MARK: - Metro

    /// Persists one line's stations and route polyline.
    @discardableResult
    static func saveMetroTopology(
        stations: [Station],
        geometry: LineGeometry?,
        lineCode: String,
        cache: DiskCache = .shared
    ) -> Bool {
        cache.save(MetroTopologySnapshot(stations: stations, geometry: geometry),
                  forKey: metroTopologyKey(lineCode: lineCode))
    }

    /// The line's last persisted topology, or nil when there is none or it
    /// does not decode.
    static func loadMetroTopology(
        lineCode: String,
        cache: DiskCache = .shared
    ) -> (stations: [Station], geometry: LineGeometry?)? {
        guard let snapshot = cache.load(MetroTopologySnapshot.self,
                                        forKey: metroTopologyKey(lineCode: lineCode)) else { return nil }
        return snapshot.apply()
    }

    // MARK: - Bus catalog

    /// Persists the full line catalog.
    @discardableResult
    static func saveBusCatalog(_ lines: [BusLine], cache: DiskCache = .shared) -> Bool {
        cache.save(lines.map(BusLineSnapshot.init), forKey: busCatalogKey)
    }

    /// The last persisted catalog, or nil when there is none or it does not
    /// decode. An empty cached catalog is dropped: the caller keeps asking
    /// the network for a real one.
    static func loadBusCatalog(cache: DiskCache = .shared) -> [BusLine]? {
        guard let snapshots = cache.load([BusLineSnapshot].self, forKey: busCatalogKey),
              !snapshots.isEmpty else { return nil }
        return snapshots.map { $0.busLine }
    }

    // MARK: - Bus topology

    /// Persists one line's stops (both directions) and route geometries.
    @discardableResult
    static func saveBusTopology(
        stops: [BusStop],
        routes: [BusRoute],
        lineCode: Int,
        cache: DiskCache = .shared
    ) -> Bool {
        cache.save(BusTopologySnapshot(stops: stops, routes: routes),
                  forKey: busTopologyKey(lineCode: lineCode))
    }

    /// The line's last persisted stops and routes, or nil when absent.
    static func loadBusTopology(
        lineCode: Int,
        cache: DiskCache = .shared
    ) -> (stops: [BusStop], routes: [BusRoute])? {
        guard let snapshot = cache.load(BusTopologySnapshot.self,
                                        forKey: busTopologyKey(lineCode: lineCode)) else { return nil }
        return snapshot.apply()
    }

    // MARK: - FGC topology

    /// Persists the merged FGC network.
    @discardableResult
    static func saveFGCTopology(
        lines: [FGCLine],
        stations: [FGCStation],
        cache: DiskCache = .shared
    ) -> Bool {
        cache.save(FGCTopologySnapshot(lines: lines, stations: stations), forKey: fgcTopologyKey)
    }

    /// The last persisted FGC network, or nil when absent.
    static func loadFGCTopology(
        cache: DiskCache = .shared
    ) -> (lines: [FGCLine], stations: [FGCStation])? {
        guard let snapshot = cache.load(FGCTopologySnapshot.self, forKey: fgcTopologyKey) else { return nil }
        return snapshot.apply()
    }
}
