import Foundation
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
@MainActor
final class LineState: ObservableObject {
    let line: MetroLine

    @Published private(set) var stations: [Station] = []
    @Published private(set) var geometry: LineGeometry?
    @Published private(set) var positions: [TrainPosition] = []
    @Published private(set) var arrivalsByStop: [Int: [Arrival]] = [:]
    @Published private(set) var isLoadingTopology = false
    @Published private(set) var isPolling = false
    @Published private(set) var errorMessage: String?

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
            let fetchedGeometry = try? await client.lineGeometry(lineCode: line.code)
            var loadedGeometry = fetchedGeometry
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
            errorMessage = error.localizedDescription
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
        if let fetched = try? await client.metroArrivals(lineCode: line.code, stationCodes: stationCodes) {
            var updated = arrivalsByStop
            for (code, arrivals) in fetched where !arrivals.isEmpty {
                updated[code] = arrivals
            }
            arrivalsByStop = updated
        }

        let all = arrivalsByStop.values.flatMap { $0 }
        positions = engine?.positions(lineCode: line.code, arrivals: all) ?? []
    }
}
