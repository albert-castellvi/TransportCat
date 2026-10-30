import Foundation
import OSLog
import Sentry
import SwiftUI

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

    init(infoDictionary: [String: Any]? = Bundle.main.infoDictionary) {
        self.client = try? TMBClient.fromBundle(infoDictionary: infoDictionary)
    }

    var missingCredentialsMessage: String? {
        client == nil ? TMBError.missingCredentials.errorDescription : nil
    }

    /// Fetches service alerts; failures surface as a message, never a crash.
    func refreshAlerts() async {
        guard let client else { return }
        isLoadingAlerts = true
        defer { isLoadingAlerts = false }
        do {
            alerts = try await client.alerts()
            alertsErrorMessage = nil
        } catch {
            alertsErrorMessage = error.localizedDescription
        }
    }

    /// Alerts that mention the given line code.
    func alerts(affecting lineCode: String) -> [ServiceAlert] {
        alerts.filter { $0.lineCodes.contains(lineCode) }
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

    /// Poll cycle for i-Metro arrivals, in seconds. 20 s keeps the request
    /// volume per visible line modest while staying visibly live.
    static let pollIntervalSeconds: UInt64 = 20

    private let client: TMBClient
    private(set) var engine: TrainPositionEngine?

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
    /// positions. Failures are tolerated: a stop missing from the response
    /// just keeps its previous arrivals.
    func pollArrivals() async {
        guard !stations.isEmpty else { return }
        isPolling = true
        defer { isPolling = false }

        let stationCodes = stations.map(\.code)
        do {
            let fetched = try await client.metroArrivals(lineCode: line.code, stationCodes: stationCodes)
            var updated = arrivalsByStop
            for (code, arrivals) in fetched where !arrivals.isEmpty {
                updated[code] = arrivals
            }
            arrivalsByStop = updated
        } catch {
            Self.report(error, "arrivals", line: line.code)
        }

        let all = arrivalsByStop.values.flatMap { $0 }
        positions = engine?.positions(lineCode: line.code, arrivals: all) ?? []
        Self.log.info("Line \(self.line.code, privacy: .public): \(all.count) arrivals, \(self.positions.count) trains")
    }
}
