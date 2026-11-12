import Foundation
import Observation

/// One metro station as a dot on the global map (spec S8).
///
/// The same physical station is served by several lines; the dot keeps the
/// color of the first line in `MetroLine.allLines` order so the set is stable
/// across rebuilds.
struct GlobalStationDot: Identifiable, Hashable {
    /// The line-independent station identity from `StationGroupKey`, unique
    /// across the map.
    let id: String
    let name: String
    let colorHex: String
    let position: GeoPoint
}

/// One metro station with at least one active incident (spec S8). The map
/// draws a warning marker for it and taps open the incident card with exactly
/// the alerts that cover the station.
struct GlobalIncidentStation: Identifiable, Hashable {
    /// The line-independent station identity from `StationGroupKey`, unique
    /// across the map.
    let id: String
    /// Per-line `CODI_ESTACIO` of the first line that reported the station.
    let stationCode: Int
    let name: String
    let position: GeoPoint
    /// The covering alerts, in feed order.
    let alerts: [ServiceAlert]
}

/// A line-independent identity of one physical metro station (spec S8): the
/// `CODI_GRUP_ESTACIO` when the line feed carries it, else the normalized name
/// plus the position rounded to three decimals (~100 m) — the offline station
/// snapshots drop the group code, so the fallback keeps an interchange served
/// by several lines together. The per-line `Station.code` is never part of the
/// key, because it differs per line.
enum StationGroupKey {
    static func key(for station: Station) -> String {
        if let groupCode = station.groupCode {
            return "g\(groupCode)"
        }
        let name = PlaceIndex.normalized(station.name)
        let latitude = Int((station.latitude * 1000).rounded())
        let longitude = Int((station.longitude * 1000).rounded())
        return "n\(name):\(latitude):\(longitude)"
    }
}

/// Live state of the whole metro network for the global mode (spec S8).
///
/// It does not re-implement any metro logic: it owns one `LineState` per
/// `MetroLine` — the exact class the metro map uses — and *drives* them from
/// outside with its own clocks, which is all the spec asks of the global
/// mode: ONE 30 s poll loop that visits every line staggered through the
/// interval, and ONE 10 Hz ticker that advances every line's interpolation.
/// Eleven independent `run()` loops (what eleven `LineState.run()` calls
/// would create) are explicitly avoided.
///
/// FGC trains are not driven here: `FGCNetworkState.shared` keeps its own
/// single poller, and `RootView` runs it in FGC *and* global modes (spec S8).
/// Bus vehicles are never polled, to protect the TMB quota.
///
/// Like `FGCNetworkState.shared` the instance is process-wide so re-entering
/// the mode resumes on the topology and trains already loaded. Its `run()`
/// is started by exactly one owner: the `.task` on `GlobalMapScreen`, which
/// cancels it the moment the rider leaves the global map.
@MainActor
@Observable
final class GlobalNetworkState {
    static let shared = GlobalNetworkState()

    /// The eleven line states, keyed by `MetroLine.code`. Empty until the
    /// first `run()` builds them.
    private(set) var lineStates: [String: LineState] = [:]
    /// Metro routes as drawable layers, ids "metro:<code>" (spec S8).
    private(set) var metroLineLayers: [MapLineLayer] = []
    /// Route polylines of the favorite bus lines, ids "bus:<code>". Fetched
    /// once per favorite set, never per poll (spec S8).
    private(set) var busLineLayers: [MapLineLayer] = []
    /// Station dots of every metro line, deduped by the line-independent
    /// station group.
    private(set) var stationDots: [GlobalStationDot] = []
    /// Live metro trains of all lines (FGC trains come from
    /// `FGCNetworkState.shared`; bus vehicles are not drawn, spec S8).
    private(set) var vehicles: [MapVehicle] = []
    /// Metro stations with an active incident (spec S8, via `IncidentIndex`).
    private(set) var incidentStations: [GlobalIncidentStation] = []
    /// Time of the newest successful arrivals poll of any line.
    private(set) var updatedAt: Date?
    /// Whether the last arrivals poll of any line failed. Like the single-line
    /// chip, a failure keeps the markers moving on last data, so it only
    /// downgrades freshness.
    private(set) var lastPollFailed = false
    /// Whether the last topology pass loaded nothing drawable (spec S8): a
    /// cold start whose every line load failed keeps the loading placeholder
    /// forever, so the screen offers a retry instead.
    private(set) var loadFailed = false

    /// Metro lines are polled once per 30 s pass (spec S8).
    static let pollIntervalSeconds: UInt64 = 30
    /// The one 10 Hz ticker, like `FGCNetworkState.tickIntervalNanoseconds`.
    static let tickIntervalNanoseconds: UInt64 = 100_000_000
    /// Delay between two line polls inside a pass: the interval spread over
    /// the eleven lines, so a pass takes ~30 s and the requests never arrive
    /// in one burst (spec S8).
    static let lineStaggerNanoseconds: UInt64 =
        pollIntervalSeconds * 1_000_000_000 / UInt64(MetroLine.allLines.count)

    /// Color of a favorite bus line whose catalog entry is not loaded yet.
    private static let unthemedColorHex = "6E6E6E"

    /// The favorite set the current `busLineLayers` were built from. Not
    /// observed: nothing on screen reads it.
    @ObservationIgnored private var fetchedBusCodes: [Int] = []

    init() {}

    /// Long-running task body, the global map's `.task` owner: build the
    /// metro line states once (topology loads concurrently), then run the one
    /// poll loop and the one ticker until the task is cancelled.
    func run() async {
        guard AppModel.shared.client != nil else { return }
        await ensureLineStates()
        loadFailed = metroLineLayers.isEmpty

        let ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.tickIntervalNanoseconds)
                self?.tickAllLines()
            }
        }
        defer { ticker.cancel() }

        // Spec S6: the very first pass polls every line back to back, so all
        // trains are on the map after one cycle instead of trickling in over
        // ~30 s. Later passes keep the stagger below.
        var isFirstPass = true
        while !Task.isCancelled {
            for line in MetroLine.allLines {
                guard let state = lineStates[line.code] else { continue }
                await state.pollArrivals()
                republishVehicles()
                // Stagger: wait out the rest of this line's slice of the
                // 30 s pass before polling the next one.
                if !isFirstPass {
                    try? await Task.sleep(nanoseconds: Self.lineStaggerNanoseconds)
                }
                if Task.isCancelled { return }
            }
            isFirstPass = false
            aggregateFreshness()
            refreshIncidents()
            await refreshBusFavoritesIfNeeded()
        }
    }

    /// Re-runs the topology load after a failure (spec S8): the "Reintenta"
    /// button of the error state. Lines that already loaded keep their state;
    /// the ones that failed are rebuilt and `loadFailed` reflects the result.
    func retryLoad() async {
        loadFailed = false
        await ensureLineStates()
        loadFailed = metroLineLayers.isEmpty
    }

    /// Re-derives `incidentStations` from `IncidentIndex` and the app's
    /// alerts feed. Called after every poll pass and whenever the alerts
    /// arrive or change (`GlobalMapScreen` watches `alertsUpdatedAt`). Cheap:
    /// the filter runs over the already-loaded stations, no network.
    func refreshIncidents() {
        let alerts = AppModel.shared.alerts
        var merged: [String: (name: String, position: GeoPoint, alertIDs: Set<String>, stationCode: Int)] = [:]
        for line in MetroLine.allLines {
            guard let state = lineStates[line.code], !state.stations.isEmpty else { continue }
            let incidents = IncidentIndex.incidents(for: alerts, stations: state.stations, lineCode: line.code)
            guard !incidents.isEmpty else { continue }
            for station in state.stations {
                guard let items = incidents[station.code] else { continue }
                let key = StationGroupKey.key(for: station)
                var entry = merged[key]
                    ?? (station.name, GeoPoint(latitude: station.latitude, longitude: station.longitude), Set<String>(), station.code)
                entry.2.formUnion(items.map(\.alertID))
                merged[key] = entry
            }
        }
        incidentStations = merged.keys.sorted().compactMap { key in
            guard let entry = merged[key] else { return nil }
            let covering = alerts.filter { entry.2.contains($0.id) }
            guard !covering.isEmpty else { return nil }
            return GlobalIncidentStation(
                id: key,
                stationCode: entry.3,
                name: entry.name,
                position: entry.position,
                alerts: covering
            )
        }
    }

    // MARK: - Metro driving

    /// Builds the missing `LineState`s and loads their topology concurrently,
    /// then publishes the layers and dots in a single rebuild (spec S7).
    /// Per-line publication would mean one full `rebuildMetroLayersAndDots()`
    /// per completed line — eleven map invalidations — so the global map fills
    /// in once, after the slowest line, instead.
    ///
    /// #27: a line whose load failed or was cancelled while leaving the map
    /// keeps an empty `stations` list, and this instance is a session
    /// singleton, so the lines that are still empty are rebuilt here instead
    /// of being skipped for the rest of the session. The lines that already
    /// loaded keep their state.
    private func ensureLineStates() async {
        guard let client = AppModel.shared.client else { return }
        let pending = Self.linesNeedingTopologyLoad(
            stationCounts: lineStates.mapValues(\.stations.count)
        )
        guard !pending.isEmpty else { return }

        var built = lineStates
        var loading: [LineState] = []
        for line in pending {
            let state = built[line.code] ?? LineState(line: line, client: client)
            built[line.code] = state
            loading.append(state)
        }
        lineStates = built

        await withTaskGroup(of: Void.self) { group in
            for state in loading {
                group.addTask {
                    await state.loadTopology()
                }
            }
            await group.waitForAll()
        }
        rebuildMetroLayersAndDots()
        refreshIncidents()
    }

    /// The lines whose topology still has to load: the ones with no state yet
    /// and the ones whose load left no stations behind (#27).
    ///
    /// `loadTopology` publishes its stations before anything else and the
    /// offline fallback publishes the cached list, so a line that loaded —
    /// online or from the cache — always has them; an empty list is exactly
    /// the signal of a failed or cancelled request.
    static func linesNeedingTopologyLoad(
        stationCounts: [String: Int],
        lines: [MetroLine] = MetroLine.allLines
    ) -> [MetroLine] {
        lines.filter { (stationCounts[$0.code] ?? 0) == 0 }
    }

    /// Advances every line's interpolation by one tick and republishes the
    /// vehicles — the single 10 Hz heartbeat of the global map (spec S8).
    private func tickAllLines() {
        for state in lineStates.values {
            state.tick()
        }
        republishVehicles()
    }

    /// Turns each line's geometry into a `MapLineLayer` and dedupes the
    /// stations into `stationDots`, both in `MetroLine.allLines` order.
    private func rebuildMetroLayersAndDots() {
        var layers: [MapLineLayer] = []
        var dots: [GlobalStationDot] = []
        var seenStations: Set<String> = []
        for line in MetroLine.allLines {
            guard let state = lineStates[line.code] else { continue }
            if let geometry = state.geometry, !geometry.points.isEmpty {
                layers.append(MapLineLayer(
                    id: "metro:\(line.code)",
                    operator: "Metro",
                    code: line.code,
                    colorHex: line.colorHex,
                    textColorHex: Self.textColor(for: line.colorHex),
                    polylines: [geometry.points]
                ))
            }
            for station in state.stations.sorted(by: { $0.orderInLine < $1.orderInLine }) {
                let key = StationGroupKey.key(for: station)
                guard seenStations.insert(key).inserted else { continue }
                dots.append(GlobalStationDot(
                    id: key,
                    name: station.name,
                    colorHex: line.colorHex,
                    position: GeoPoint(latitude: station.latitude, longitude: station.longitude)
                ))
            }
        }
        metroLineLayers = layers
        stationDots = dots
    }

    /// All trains of all lines as shared layer values, in
    /// `MetroLine.allLines` order then station order within the line. Ids are
    /// the engine ids, which are stable across polls, so the markers glide.
    private func republishVehicles() {
        var result: [MapVehicle] = []
        for line in MetroLine.allLines {
            guard let state = lineStates[line.code] else { continue }
            for position in state.positions {
                result.append(MapVehicle(
                    id: position.id,
                    lineCode: line.code,
                    colorHex: line.colorHex,
                    position: position.position,
                    heading: position.heading,
                    label: position.destination
                ))
            }
        }
        vehicles = result
    }

    /// The chip values for the whole network: the newest successful poll and
    /// whether any line's last attempt failed.
    private func aggregateFreshness() {
        updatedAt = lineStates.values.compactMap(\.arrivalsUpdatedAt).max()
        lastPollFailed = lineStates.values.contains { $0.lastPollFailed }
    }

    /// Metro badges carry no published text color, so the choice follows the
    /// WCAG luminance rule used by the arrival pills.
    private static func textColor(for colorHex: String) -> String {
        HexLuminance.isLight(colorHex) ? "111111" : "FFFFFF"
    }

    // MARK: - Favorite bus routes

    /// Rebuilds `busLineLayers` when the favorite set changed since the last
    /// fetch (spec S8: "once per favorite set"). The catalog load itself is
    /// the store's once-per-launch guard; routes come from `/recs`.
    private func refreshBusFavoritesIfNeeded() async {
        guard let client = AppModel.shared.client else { return }
        await BusCatalogStore.shared.load(client: client)
        let favorites = BusCatalogStore.shared.favorites
        guard favorites != fetchedBusCodes else { return }

        // Only the favorites that have not answered yet are asked: a code
        // that keeps failing must not make the others download again.
        let alreadyFetched = Set(fetchedBusCodes)
        var routePolylines: [Int: [[GeoPoint]]] = [:]
        for code in favorites where !alreadyFetched.contains(code) {
            guard let routes = try? await client.busRoutes(lineCode: code) else { continue }
            routePolylines[code] = routes.map(\.geometry.points).filter { !$0.isEmpty }
        }
        let pass = Self.busLayerPass(
            favorites: favorites,
            previousLayers: busLineLayers,
            fetchedRoutePolylines: routePolylines,
            lines: BusCatalogStore.shared.lines
        )
        busLineLayers = pass.layers
        let answered = alreadyFetched.union(pass.fetchedCodes)
        fetchedBusCodes = favorites.filter(answered.contains)
    }

    /// Folds one bus favorites pass into the layer set (spec S8): a favorite
    /// whose routes arrived replaces its layer, a favorite whose fetch failed
    /// keeps the layer it already had, and only the codes that answered count
    /// as fetched so the next pass retries the rest. Pure for the tests.
    static func busLayerPass(
        favorites: [Int],
        previousLayers: [MapLineLayer],
        fetchedRoutePolylines: [Int: [[GeoPoint]]],
        lines: [BusLine]
    ) -> (layers: [MapLineLayer], fetchedCodes: [Int]) {
        var layersByCode: [Int: MapLineLayer] = [:]
        for layer in previousLayers {
            if let code = Int(layer.code) { layersByCode[code] = layer }
        }
        var fetchedCodes: [Int] = []
        for code in favorites {
            guard let polylines = fetchedRoutePolylines[code] else { continue }
            fetchedCodes.append(code)
            guard !polylines.isEmpty else {
                // An answer with nothing to draw replaces the old layer too.
                layersByCode[code] = nil
                continue
            }
            let line = lines.first { $0.code == code }
            layersByCode[code] = MapLineLayer(
                id: "bus:\(code)",
                operator: "Bus",
                code: String(code),
                colorHex: line?.colorHex ?? Self.unthemedColorHex,
                textColorHex: line?.textColorHex ?? "FFFFFF",
                polylines: polylines
            )
        }
        return (favorites.compactMap { layersByCode[$0] }, fetchedCodes)
    }
}
