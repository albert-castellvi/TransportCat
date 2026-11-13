import Foundation
import Observation
import OSLog
import Sentry
import SwiftUI

/// Monotonic clock for poll latency: wall-clock time would report nonsense
/// after an NTP step or a timezone change.
private let pollClock = ContinuousClock()

/// Milliseconds elapsed since `start`, truncated. `Duration` has no portable
/// ratio operator, so its components are converted by hand.
private func elapsedMilliseconds(since start: ContinuousClock.Instant) -> Int {
    let elapsed = pollClock.now - start
    let components = elapsed.components
    let milliseconds = Double(components.seconds) * 1_000
        + Double(components.attoseconds) / 1_000_000_000_000_000
    return Int(milliseconds)
}

/// Sentry breadcrumb for one poll (spec S4): category `poll`, with the latency
/// and counters that explain a slow or empty refresh.
///
/// Breadcrumbs only: a transient network failure stays out of the event stream,
/// exactly as before, so the breadcrumb trail still shows the last attempts
/// when a real error is captured.
private func addPollBreadcrumb(_ message: String, data: [String: Any]) {
    let crumb = Breadcrumb(level: .info, category: "poll")
    crumb.message = message
    crumb.data = data
    SentrySDK.addBreadcrumb(crumb)
}

/// App-wide model: owns the TMB client and the service alerts feed.
@MainActor
final class AppModel: ObservableObject {
    /// Shared instance for the root view; created on the main actor.
    static let shared = AppModel()

    /// nil when the build has no TMB credentials injected; screens then show
    /// a configuration error instead of an empty feed.
    let client: TMBClient?

    /// The timetable of the network, downloaded from the CI-published release
    /// and cached (schedule S2b, S6). A missing or unreachable pack silently
    /// turns every schedule feature off: nothing else in the app depends on it.
    ///
    /// The store is shared because the cache folder is: two screens of the same
    /// line reuse the copy the first one downloaded.
    let schedule = ScheduleStore.shared

    @Published var alerts: [ServiceAlert] = []
    @Published var alertsErrorMessage: String?
    @Published var isLoadingAlerts = false
    /// Time of the last successful alerts load; nil until one succeeds.
    /// A failed refresh keeps the previous alerts and leaves this untouched, so
    /// the UI can tell "stale but real" from "never loaded".
    @Published private(set) var alertsUpdatedAt: Date?

    /// Bumped every time a line's topology and its offline copy have landed
    /// (#55). The chrome derives its labels from those copies (the metro
    /// termini, the bus directions), so a mounted accessory reads them again
    /// when this moves instead of keeping the empty read it did before the
    /// first fetch answered.
    @Published private(set) var topologyRevision = 0

    /// Bus incidents (`/alerts/bus/channels/WEB`, spec S7). Same lifecycle as
    /// the metro alerts: loaded by `startAlertsPolling`, kept on a failure.
    @Published var busAlerts: [ServiceAlert] = []
    /// Time of the last successful bus alerts load; nil until one succeeds.
    @Published private(set) var busAlertsUpdatedAt: Date?

    /// Alerts poll period. TMB refreshes the alert feed on the order of
    /// minutes, so a minute keeps incidents visible without hammering the API.
    static let alertsPollIntervalNanoseconds: UInt64 = 60_000_000_000

    init(infoDictionary: [String: Any]? = Bundle.main.infoDictionary) {
        self.client = try? TMBClient.fromBundle(infoDictionary: infoDictionary)
        startScheduleRefresh()
    }

    /// Fetches the timetable index once, off the main thread: it is a few
    /// kilobytes, it never blocks launch, and a failure only leaves the feature
    /// off (schedule S2b).
    nonisolated func startScheduleRefresh() {
        Task.detached(priority: .background) {
            await ScheduleStore.shared.refreshIndex()
        }
    }

    var missingCredentialsMessage: String? {
        client == nil ? TMBError.missingCredentials.errorDescription : nil
    }

    /// Fetches service alerts; failures surface as a message, never a crash.
    /// Only a successful load stamps `alertsUpdatedAt` (spec S1).
    func refreshAlerts() async {
        guard let client else { return }
        isLoadingAlerts = true
        defer { isLoadingAlerts = false }
        let start = pollClock.now
        do {
            let loaded = try await client.alerts()
            alerts = loaded
            alertsUpdatedAt = Date()
            alertsErrorMessage = nil
            addPollBreadcrumb("alerts", data: [
                "line": "alerts",
                "latency_ms": elapsedMilliseconds(since: start),
                "ok": true,
                "alerts": loaded.count,
            ])
        } catch {
            alertsErrorMessage = error.localizedDescription
            addPollBreadcrumb("alerts failed", data: [
                "line": "alerts",
                "latency_ms": elapsedMilliseconds(since: start),
                "ok": false,
                "alerts": alerts.count,
            ])
        }

        // Spec S7: the bus feed is a separate endpoint, so it gets its own
        // attempt. One of the two failing must never blank the other's chips.
        let busStart = pollClock.now
        do {
            let loaded = try await client.busAlerts()
            busAlerts = loaded
            busAlertsUpdatedAt = Date()
            addPollBreadcrumb("bus alerts", data: [
                "line": "bus alerts",
                "latency_ms": elapsedMilliseconds(since: busStart),
                "ok": true,
                "alerts": loaded.count,
            ])
        } catch {
            addPollBreadcrumb("bus alerts failed", data: [
                "line": "bus alerts",
                "latency_ms": elapsedMilliseconds(since: busStart),
                "ok": false,
                "alerts": busAlerts.count,
            ])
        }
    }

    /// Signals the chrome that a line's topology cache has a fresh copy (#55),
    /// once the background write returns: a read that beat the file would leave
    /// the accessory's labels empty again.
    ///
    /// The write itself happens off the main actor (`saveInBackground`), so the
    /// callers hand in the task it returned instead of bumping immediately.
    static func topologyWillPublish(after save: Task<Void, Never>?) {
        Task { @MainActor in
            if let save { _ = await save.value }
            shared.topologyDidPublish()
        }
    }

    /// Bumps `topologyRevision`, redrawing the chrome that reads the caches.
    private func topologyDidPublish() {
        topologyRevision &+= 1
    }

    /// Loads the alerts immediately and then every minute until the task is
    /// cancelled (spec S1): every tab sees the incidents without opening Avisos
    /// first, and they do not go stale while the app stays on the map.
    func startAlertsPolling() async {
        while !Task.isCancelled {
            await refreshAlerts()
            try? await Task.sleep(nanoseconds: Self.alertsPollIntervalNanoseconds)
        }
    }

    /// Alerts that mention the given line code.
    func alerts(affecting lineCode: String) -> [ServiceAlert] {
        alerts.filter { $0.lineCodes.contains(lineCode) }
    }

    /// Alerts of the line that are in force right now (spec S3): scheduled
    /// disruptions are in the feed long before they affect a trip, so the chips
    /// count only the ones happening now.
    func activeAlerts(affecting lineCode: String, now: Date = Date()) -> [ServiceAlert] {
        alerts(affecting: lineCode).filter { $0.isActive(now: now) }
    }

    /// Bus incidents of the line that are in force right now (spec S7), with
    /// the same rule as the metro ones: scheduled disruptions are in the feed
    /// long before they matter.
    func activeBusAlerts(affecting lineCode: String, now: Date = Date()) -> [ServiceAlert] {
        busAlerts
            .filter { $0.lineCodes.contains(lineCode) }
            .filter { $0.isActive(now: now) }
    }
}

/// State of the currently selected line: topology (loaded once) plus a
/// polling cycle of i-Metro arrivals that feeds the position engine.
///
/// `@Observable` rather than `ObservableObject`: the screens hold it in an
/// optional `@State`, which does not subscribe to `@Published` changes, so
/// the map and diagram never redrew after the data arrived.
@MainActor
@Observable
final class LineState {
    let line: MetroLine

    private(set) var stations: [Station] = []
    private(set) var geometry: LineGeometry?
    private(set) var positions: [TrainPosition] = []
    private(set) var arrivalsByStop: [Int: [Arrival]] = [:]
    private(set) var isLoadingTopology = false
    private(set) var isPolling = false
    private(set) var errorMessage: String?
    /// Time of the last successful arrivals poll; nil until one succeeds (S3).
    private(set) var arrivalsUpdatedAt: Date?
    /// Whether the last arrivals poll failed; a failure keeps the markers on the
    /// last known data, so it downgrades the freshness instead of clearing it.
    private(set) var lastPollFailed = false
    /// A successful poll answered with no arrivals at all for the line: L9N,
    /// L9S, L10N, L10S and FM have no live feed (S3, S8).
    private(set) var isFeedEmpty = false

    /// True while the markers come from the timetable instead of the feed
    /// (schedule S6): the line's feed is empty and the schedule pack has it.
    /// The UI labels the markers accordingly, they are never presented as
    /// observed trains.
    private(set) var isTheoretical = false

    /// This line's timetable, loaded once in `loadTopology` (schedule S6). Nil
    /// when the bundle carries no pack or it has no entry for this line.
    private(set) var scheduleLine: ScheduleLine?

    /// Poll cycle for i-Metro arrivals, in seconds. 20 s keeps the request
    /// volume per visible line modest while staying visibly live.
    static let pollIntervalSeconds: UInt64 = 20
    /// First pause before retrying a failed topology load, and the cap the
    /// delay doubles up to (#67).
    static let topologyRetryInitialSeconds: UInt64 = 5
    static let topologyRetryMaxSeconds: UInt64 = 60

    private let client: TMBClient
    private(set) var engine: TrainPositionEngine?

    /// Smooth, per-second movement between the 20 s polls (S4). Not observed:
    /// only `positions`, the value it publishes, drives the UI.
    @ObservationIgnored private var motion = TrainMotion()

    init(line: MetroLine, client: TMBClient) {
        self.line = line
        self.client = client
    }

    /// Long-running task body: load topology, retrying while it has no engine,
    /// then poll arrivals until the task is cancelled (the view's .task
    /// modifier cancels on disappear).
    func run() async {
        // #67: a failed first load used to end the task for good, so a cold
        // launch without connectivity stayed on the error overlay after the
        // network returned. Retry with a growing, capped delay while the line
        // still has no engine and the screen is alive.
        var retryDelay = Self.topologyRetryInitialSeconds
        while !Task.isCancelled && engine == nil {
            await loadTopology()
            guard engine == nil, !Task.isCancelled else { break }
            do {
                try await Task.sleep(nanoseconds: retryDelay * 1_000_000_000)
            } catch {
                return
            }
            retryDelay = min(retryDelay * 2, Self.topologyRetryMaxSeconds)
        }
        guard engine != nil else { return }
        // 10 Hz ticker between the 20 s polls: the markers move smoothly
        // instead of hopping once per second, and the velocity controller in
        // `TrainMotion` gets small steps to ease over (S1).
        let ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                self?.tick()
            }
        }
        defer { ticker.cancel() }
        while !Task.isCancelled {
            await pollArrivals()
            do {
                try await Task.sleep(nanoseconds: Self.pollIntervalSeconds * 1_000_000_000)
            } catch {
                return
            }
        }
    }

    /// Loads the line topology: stations (required) and the line geometry
    /// (best effort). A failing geometry falls back to a straight polyline
    /// through the stations so the map, the diagram and the trains still
    /// render, and is not reported as an error.
    ///
    /// Spec S1: a cached copy is published before the first request, so a warm
    /// launch paints the line instead of an empty map while the network
    /// answers. The refresh below still replaces it and a failed refresh still
    /// falls back to it (S21). Spec S3: the timetable does not gate the
    /// topology and stations and geometry are requested together.
    func loadTopology() async {
        isLoadingTopology = true
        defer { isLoadingTopology = false }
        // Spec S1: disk first. `applyCachedTopology` publishes exactly what a
        // successful load publishes and never re-saves what it just read.
        applyCachedTopology()
        // Spec S3: the timetable does not depend on either request, and it only
        // decides whether a line without a live feed can be drawn, so it gets
        // its own task instead of holding the paint.
        Task { [weak self] in
            await self?.loadScheduleLine()
        }
        do {
            async let stationsRequest = client.stations(lineCode: line.code)
            async let geometryRequest = Self.fetchGeometry(client: client, lineCode: line.code)
            let loadedStations = try await stationsRequest
            // Spec S2: publishing the stations is what leaves the loader, so
            // the geometry is awaited after them rather than holding both.
            stations = loadedStations
            Self.log.info("Line \(self.line.code, privacy: .public): \(loadedStations.count) stations")
            var loadedGeometry = await geometryRequest
            if loadedGeometry?.points.isEmpty ?? true {
                loadedGeometry = Self.stationsPolyline(from: loadedStations)
            }
            geometry = loadedGeometry
            engine = loadedGeometry.flatMap {
                TrainPositionEngine.make(stations: loadedStations, geometry: $0)
            }
            errorMessage = engine == nil && loadedStations.count >= 2
                ? String(localized: "No s'ha pogut projectar la línia sobre la seva geometria.")
                : nil
            // Spec S21: a successful load is the moment to refresh this
            // line's offline copy. S5: the encode and the write happen off the
            // main actor, so the fresh map does not wait for the disk.
            let saved = OfflineCache.saveMetroTopology(
                stations: loadedStations, geometry: loadedGeometry, lineCode: line.code
            )
            // #55: the chrome re-reads the metro termini from this copy.
            AppModel.topologyWillPublish(after: saved)
        } catch {
            Self.report(error, "stations", line: line.code)
            // Spec S21: a failed load falls back to the cached topology, so
            // an offline launch still draws the line and its theoretical
            // trains instead of an error. The copy applied above is that
            // fallback; only a cold start without one reports the error.
            if !applyCachedTopology() {
                errorMessage = String(localized: "No s'ha pogut carregar la línia. Torna-ho a provar.")
            }
        }
    }

    /// The line's polyline, best effort (spec S3): it is requested next to the
    /// stations and a failure is logged and reported, then answered with nil so
    /// the caller keeps the straight-line fallback.
    private static func fetchGeometry(client: TMBClient, lineCode: String) async -> LineGeometry? {
        do {
            return try await client.lineGeometry(lineCode: lineCode)
        } catch {
            report(error, "geometry", line: lineCode)
            return nil
        }
    }

    /// Publishes the line's cached topology exactly as a successful load
    /// does, without re-saving it. Returns whether the cache had a copy
    /// (specs S1, S21): `loadTopology` calls it first for the warm-launch paint
    /// and again when the network fails.
    @discardableResult
    private func applyCachedTopology() -> Bool {
        guard let cached = OfflineCache.loadMetroTopology(lineCode: line.code) else { return false }
        stations = cached.stations
        geometry = cached.geometry
        engine = cached.geometry.flatMap {
            TrainPositionEngine.make(stations: cached.stations, geometry: $0)
        }
        errorMessage = engine == nil && cached.stations.count >= 2
            ? String(localized: "No s'ha pogut projectar la línia sobre la seva geometria.")
            : nil
        Self.log.info("Line \(self.line.code, privacy: .public): \(cached.stations.count) stations (offline cache)")
        return true
    }

    private static let log = Logger(subsystem: "cat.transport.app", category: "LineState")

    /// Modes the schedule pack may file this line under: the metro entry keyed
    /// by the numeric TMB code, plus the funicular for the FM line, whose
    /// timetable is its own mode in the pack.
    private var scheduleRequests: [(mode: ScheduleMode, code: Int)] {
        guard let code = Int(line.code) else { return [] }
        return line.code == "99"
            ? [(mode: .funicular, code: code), (mode: .metro, code: code)]
            : [(mode: .metro, code: code)]
    }

    /// Loads this line's timetable: the store answers from its cache, or
    /// downloads this one line file, so the network and the JSON decoding both
    /// happen outside a screen update (S8). Safe to call more than once; the
    /// second call is a no-op.
    ///
    /// The store comes from `AppModel.shared` because the screens build this
    /// state as `LineState(line:client:)` and an app without a timetable must
    /// keep working unchanged: the property degrades to nil instead of forcing a
    /// new parameter through every call site.
    private func loadScheduleLine() async {
        guard scheduleLine == nil else { return }
        let store = AppModel.shared.schedule
        for request in scheduleRequests {
            if let line = await store.line(mode: request.mode, code: request.code) {
                scheduleLine = line
                return
            }
        }
    }

    /// Logs a failed request and reports it to Sentry as a non-fatal event,
    /// so a blank map in the field can be traced to its cause.
    private static func report(_ error: Error, _ request: String, line: String) {
        log.error("Line \(line, privacy: .public) \(request, privacy: .public) failed: \(SecretRedactor.redact(String(describing: error)), privacy: .public)")
        guard !error.isTransientNetworkFailure else { return }
        SentrySDK.capture(error: error) { scope in
            scope.setTag(value: request, key: "tmb.request")
            scope.setTag(value: line, key: "tmb.line")
        }
    }

    /// Coarse fallback route when the geometry request fails: the stations
    /// joined in `ORDRE_ESTACIO` order. Enough for the polyline overlay and
    /// for the engine, which projects stations onto the polyline.
    private static func stationsPolyline(from stations: [Station]) -> LineGeometry? {
        let points = stations
            .sorted { $0.orderInLine < $1.orderInLine }
            .map { GeoPoint(latitude: $0.latitude, longitude: $0.longitude) }
        return points.isEmpty ? nil : LineGeometry(points: points)
    }

    /// Requests arrivals for the whole line in one call and recomputes train
    /// positions. The response covers every station of the line, so a station
    /// missing from it has no trains: keeping its older arrivals would leave a
    /// ghost that wins the one-marker-per-train collapse with a stale
    /// countdown. Online, a failed poll changes nothing: the markers keep
    /// moving on the last known data instead of being re-anchored to it.
    /// Offline, the timetable takes the markers over (spec S21).
    func pollArrivals() async {
        guard !stations.isEmpty else { return }
        isPolling = true
        defer { isPolling = false }

        let start = pollClock.now
        let stationCodes = stations.map(\.code)
        let fetched: [Int: [Arrival]]
        do {
            fetched = try await client.metroArrivals(lineCode: line.code, stationCodes: stationCodes)
        } catch {
            lastPollFailed = true
            Self.report(error, "arrivals", line: line.code)
            addPollBreadcrumb("arrivals failed", data: [
                "line": line.code,
                "latency_ms": elapsedMilliseconds(since: start),
                "ok": false,
                "arrivals": 0,
                "trains": 0,
            ])
            // Spec S21: with no path to the feed, the markers move to the
            // timetable instead of coasting on the last live snapshot. Online,
            // a failed poll changes nothing, as before.
            if FleetSourceRule.useTheoreticalFleet(
                isFeedEmpty: isFeedEmpty,
                isOffline: !ConnectivityMonitor.shared.isOnline,
                hasSchedule: scheduleLine != nil,
                hasEngine: engine != nil
            ) {
                isTheoretical = true
                positions = theoreticalPositions(now: Date())
            }
            return
        }

        arrivalsByStop = fetched
        arrivalsUpdatedAt = Date()
        lastPollFailed = false
        let feedWasEmpty = isFeedEmpty
        let all = fetched.values.flatMap { $0 }
        isFeedEmpty = all.isEmpty
        // A line whose feed is always empty but whose timetable is available is
        // drawn from it instead of staying blank (schedule S6); offline the
        // timetable takes over even from a feed that had trains (spec S21).
        // Online with trains the condition is exactly the one from S6.
        isTheoretical = FleetSourceRule.useTheoreticalFleet(
            isFeedEmpty: isFeedEmpty,
            isOffline: !ConnectivityMonitor.shared.isOnline,
            hasSchedule: scheduleLine != nil,
            hasEngine: engine != nil
        )
        var trainCount = 0
        if isTheoretical {
            let scheduled = theoreticalPositions(now: Date())
            positions = scheduled
            trainCount = scheduled.count
        } else {
            let computed = engine?.positions(lineCode: line.code, arrivals: all) ?? []
            motion.update(with: computed, now: Date())
            positions = engine.map { motion.advance(to: Date(), engine: $0) } ?? []
            trainCount = computed.count
        }
        addPollBreadcrumb("arrivals", data: [
            "line": line.code,
            "latency_ms": elapsedMilliseconds(since: start),
            "ok": true,
            "arrivals": all.count,
            "trains": trainCount,
            "theoretical": isTheoretical,
        ])
        if isFeedEmpty, !feedWasEmpty {
            addPollBreadcrumb("feed empty", data: ["line": line.code])
        }
        let mode = isTheoretical ? "theoretical" : "live"
        Self.log.info("Line \(self.line.code, privacy: .public): \(all.count) arrivals, \(trainCount) trains, \(mode, privacy: .public)")
    }

    /// Scheduled positions of the trains the line should have right now, or an
    /// empty list when there is no timetable for it (schedule S6).
    private func theoreticalPositions(now: Date) -> [TrainPosition] {
        guard let scheduleLine, let engine else { return [] }
        return TheoreticalFleet.positions(line: scheduleLine, stations: stations, engine: engine, now: now)
    }

    /// Live arrivals at a station against the timetable of the same direction
    /// (schedule S6, S3). `via` follows the map's convention: 1 travels toward
    /// the line's last station, 2 toward the first. Nil when there is no
    /// timetable for the line or no scheduled direction matching `via`, which
    /// is what leaves the regularity tag off the screen.
    func regularity(stationCode: Int, via: Int, now: Date) -> RegularityReport? {
        guard let scheduleLine,
              let directionID = scheduledDirectionID(via: via, schedule: scheduleLine) else { return nil }
        let live = (arrivalsByStop[stationCode] ?? []).compactMap { arrival -> Date? in
            guard let seconds = arrival.seconds else { return nil }
            return now.addingTimeInterval(Double(seconds))
        }
        let scheduled = scheduleLine.arrivals(at: stationCode, directionID: directionID, on: now)
        return Regularity.assess(live: live, scheduled: scheduled, now: now)
    }

    /// Scheduled direction that travels the way `via` says: a pattern that
    /// starts at a lower station index than it ends is the forward one, and
    /// station indexes come from the line's own station order (S6).
    private func scheduledDirectionID(via: Int, schedule: ScheduleLine) -> Int? {
        guard via == 1 || via == 2 else { return nil }
        var indexByCode: [Int: Int] = [:]
        for (index, station) in stations.enumerated() {
            indexByCode[station.code] = index
        }
        let wantsForward = via == 1
        return schedule.directions.first { direction in
            direction.patterns.contains { pattern in
                guard let first = pattern.stops.first.flatMap({ indexByCode[$0] }),
                      let last = pattern.stops.last.flatMap({ indexByCode[$0] }),
                      first != last else { return false }
                return (last > first) == wantsForward
            }
        }?.id
    }

    /// How old the arrivals behind the markers are (spec S3).
    func freshness(now: Date = Date()) -> DataFreshness {
        Freshness.level(
            lastUpdate: arrivalsUpdatedAt,
            now: now,
            lastAttemptFailed: lastPollFailed
        )
    }

    /// Advances the interpolated markers by one tick. Called by the 10 Hz
    /// ticker in `run()`; does nothing until the topology is loaded. A line
    /// drawn from its timetable is re-evaluated here, because a theoretical
    /// train also has to move between polls (schedule S6).
    func tick() {
        guard let engine else { return }
        if isTheoretical {
            // #38: a timetable is not an animation state. Dropping the
            // retained distances here is what keeps the live transition from
            // easing out of the last live poll's positions when the feed
            // comes back.
            motion.reset()
            positions = theoreticalPositions(now: Date())
            return
        }
        positions = motion.advance(to: Date(), engine: engine)
    }
}
