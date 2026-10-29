import Foundation
import SwiftUI

/// App-wide model: owns the TMB client and the service alerts feed.
@MainActor
final class AppModel: ObservableObject {
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
/// polling cycle of iBus arrivals that feeds the position engine.
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

    /// Poll cycle for iBus arrivals, in seconds. 20 s keeps the request
    /// volume per visible line modest while staying visibly live.
    static let pollIntervalSeconds: UInt64 = 20

    private let client: TMBClient
    private var engine: TrainPositionEngine?

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

    private func loadTopology() async {
        isLoadingTopology = true
        defer { isLoadingTopology = false }
        do {
            async let stationsTask = client.stations(lineCode: line.code)
            async let geometryTask = client.lineGeometry(lineCode: line.code)
            let (loadedStations, loadedGeometry) = try await (stationsTask, geometryTask)
            stations = loadedStations
            geometry = loadedGeometry
            engine = TrainPositionEngine.make(stations: loadedStations, geometry: loadedGeometry)
            errorMessage = engine == nil && loadedStations.count >= 2
                ? "No s'ha pogut projectar la línia sobre la seva geometria."
                : nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Polls arrivals for every station of the line concurrently and
    /// recomputes train positions. Failures per stop are tolerated: a stop
    /// that errors just keeps its previous arrivals.
    func pollArrivals() async {
        guard !stations.isEmpty else { return }
        isPolling = true
        defer { isPolling = false }

        await withTaskGroup(of: (Int, [Arrival]).self) { group in
            for station in stations {
                group.addTask {
                    let arrivals = (try? await self.client.arrivals(lineCode: self.line.code, stopCode: station.code)) ?? []
                    return (station.code, arrivals)
                }
            }
            var updated = arrivalsByStop
            for await (code, arrivals) in group where !arrivals.isEmpty {
                updated[code] = arrivals
            }
            arrivalsByStop = updated
        }

        let all = arrivalsByStop.values.flatMap { $0 }
        positions = engine?.positions(lineCode: line.code, arrivals: all) ?? []
    }
}
