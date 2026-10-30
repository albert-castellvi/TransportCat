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

    @Published var alerts: [ServiceAlert] = []
    @Published var alertsErrorMessage: String?
    @Published var isLoadingAlerts = false
    /// Time of the last successful alerts load; nil until one succeeds.
    /// A failed refresh keeps the previous alerts and leaves this untouched, so
    /// the UI can tell "stale but real" from "never loaded".
    @Published private(set) var alertsUpdatedAt: Date?

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

    /// Poll cycle for i-Metro arrivals, in seconds. 20 s keeps the request
    /// volume per visible line modest while staying visibly live.
    static let pollIntervalSeconds: UInt64 = 20

    private let client: TMBClient
    private(set) var engine: TrainPositionEngine?

    /// Smooth, per-second movement between the 20 s polls (S4). Not observed:
    /// only `positions`, the value it publishes, drives the UI.
    @ObservationIgnored private var motion = TrainMotion()

    init(line: MetroLine, client: TMBClient) {
        self.line = line
        self.client = client
    }

    /// Long-running task body: load topology once, then poll arrivals until
    /// the task is cancelled (the view's .task modifier cancels on disappear).
    func run() async {
        if stations.isEmpty || geometry == nil {
            await loadTopology()
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
    func loadTopology() async {
        isLoadingTopology = true
        defer { isLoadingTopology = false }
        do {
            let loadedStations = try await client.stations(lineCode: line.code)
            stations = loadedStations
            Self.log.info("Line \(self.line.code, privacy: .public): \(loadedStations.count) stations")
            var loadedGeometry: LineGeometry?
            do {
                loadedGeometry = try await client.lineGeometry(lineCode: line.code)
            } catch {
                Self.report(error, "geometry", line: line.code)
            }
            if loadedGeometry?.points.isEmpty ?? true {
                loadedGeometry = Self.stationsPolyline(from: loadedStations)
            }
            geometry = loadedGeometry
            engine = loadedGeometry.flatMap {
                TrainPositionEngine.make(stations: loadedStations, geometry: $0)
            }
            errorMessage = engine == nil && loadedStations.count >= 2
                ? "No s'ha pogut projectar la línia sobre la seva geometria."
                : nil
        } catch {
            Self.report(error, "stations", line: line.code)
            errorMessage = error.localizedDescription
        }
    }

    private static let log = Logger(subsystem: "cat.transport.app", category: "LineState")

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
    /// countdown. A failed poll changes nothing: the markers keep moving on
    /// the last known data instead of being re-anchored to it.
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
            return
        }

        arrivalsByStop = fetched
        arrivalsUpdatedAt = Date()
        lastPollFailed = false
        let feedWasEmpty = isFeedEmpty
        let all = fetched.values.flatMap { $0 }
        isFeedEmpty = all.isEmpty
        let computed = engine?.positions(lineCode: line.code, arrivals: all) ?? []
        motion.update(with: computed, now: Date())
        positions = engine.map { motion.advance(to: Date(), engine: $0) } ?? []
        addPollBreadcrumb("arrivals", data: [
            "line": line.code,
            "latency_ms": elapsedMilliseconds(since: start),
            "ok": true,
            "arrivals": all.count,
            "trains": computed.count,
        ])
        if isFeedEmpty, !feedWasEmpty {
            addPollBreadcrumb("feed empty", data: ["line": line.code])
        }
        Self.log.info("Line \(self.line.code, privacy: .public): \(all.count) arrivals, \(computed.count) trains")
    }

    /// How old the arrivals behind the markers are (spec S3).
    func freshness(now: Date = Date()) -> DataFreshness {
        Freshness.level(
            lastUpdate: arrivalsUpdatedAt,
            now: now,
            lastAttemptFailed: lastPollFailed
        )
    }

    /// Advances the interpolated markers by one tick. Called by the one-second
    /// ticker in `run()`; does nothing until the topology is loaded.
    func tick() {
        guard let engine else { return }
        positions = motion.advance(to: Date(), engine: engine)
    }
}
