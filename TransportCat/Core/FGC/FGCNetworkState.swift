import Foundation
import Observation

#if canImport(Sentry)
import Sentry
#endif

/// Monotonic clock for poll latency, same approach as `AppModel` and
/// `BusLineState`: wall-clock time would report nonsense after an NTP step.
private let pollClock = ContinuousClock()

/// Milliseconds elapsed since `start`, truncated.
private func elapsedMilliseconds(since start: ContinuousClock.Instant) -> Int {
    let elapsed = pollClock.now - start
    let components = elapsed.components
    let milliseconds = Double(components.seconds) * 1_000
        + Double(components.attoseconds) / 1_000_000_000_000_000
    return Int(milliseconds)
}

/// Sentry breadcrumb for one FGC poll: category `poll`, with the `line` tag
/// and counters that explain a slow or empty refresh. Breadcrumbs only, like
/// `AppModel.pollBreadcrumb`: a transient failure must not flood the events.
private func addPollBreadcrumb(_ message: String, data: [String: Any]) {
    #if canImport(Sentry)
    let crumb = Breadcrumb(level: .info, category: "poll")
    crumb.message = message
    crumb.data = data
    SentrySDK.addBreadcrumb(crumb)
    #endif
}

/// Motion bookkeeping of one train between two polls (spec S5).
///
/// `TrainMotion` from the metro engine is not reused here: it is driven by a
/// `TrainPositionEngine` with an engine speed and a segment end, while FGC
/// gives a GPS point per poll and asks only for a glide from distance A to B
/// over the poll interval. This value stores exactly that, and the glide
/// itself is the pure `FGCNetwork.glide`.
private struct FGCMotion {
    let train: FGCTrain
    /// Base line code after alias resolution; keys `geometryByLine`.
    let lineCode: String
    let colorHex: String
    let snapped: Bool
    let polylineIndex: Int
    let startDistance: Double
    let targetDistance: Double
    /// Whether the train runs against the polyline's drawn order, so its
    /// marker faces opposite to the track bearing.
    let reversed: Bool
    let startedAt: Date
    let rawPosition: GeoPoint
    /// Heading used while the train is drawn raw (no track to follow).
    let rawHeading: Double
}

/// State of the FGC mode: topology (loaded once, spec S2), a 30 s live-train
/// poll (S3) and the 10 Hz glide between polls (S5). It also publishes its
/// drawable content as the shared layer values of S11.
@MainActor
@Observable
final class FGCNetworkState {
    /// Lines of the network, loaded once per launch (S2).
    private(set) var lines: [FGCLine] = []
    /// Stations with coordinates joined from the stop catalog (S2).
    private(set) var stations: [FGCStation] = []
    /// Trains of the last successful poll (S3), keyed by `id` for the sheet.
    private(set) var trains: [FGCTrain] = []
    /// Drawable lines for the map (S11).
    private(set) var lineLayers: [MapLineLayer] = []
    /// Smoothed trains of every line; the UI filters by line (S5, S11).
    private(set) var vehicles: [MapVehicle] = []
    /// Time of the last successful poll; nil until one succeeds.
    private(set) var arrivalsUpdatedAt: Date?
    /// Whether the last poll failed. A failed poll keeps the last markers
    /// moving, so it downgrades freshness instead of clearing the map.
    private(set) var lastPollFailed = false
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    /// The position feed refreshes on the server about every 30 s.
    static let pollIntervalSeconds: UInt64 = 30
    /// 10 Hz ticker between polls, like `BusLineState.run()`.
    static let tickIntervalNanoseconds: UInt64 = 100_000_000

    private let client: FGCClient

    /// Station code -> name, used to resolve each train's `desti` (S2).
    @ObservationIgnored private var stationNamesByCode: [String: String] = [:]
    /// Base line code -> precomputed geometry (S5).
    @ObservationIgnored private var geometryByLine: [String: FGCLineGeometry] = [:]
    /// Train id -> motion state. Not observed: `vehicles` is what the UI reads.
    @ObservationIgnored private var motions: [String: FGCMotion] = [:]

    init(client: FGCClient = FGCClient()) {
        self.client = client
    }

    /// Long-running task body: load topology once, then poll until cancelled
    /// (the screen's `.task` cancels on disappear).
    func run() async {
        if lines.isEmpty {
            await loadTopology()
        }
        guard !lines.isEmpty else { return }

        let ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.tickIntervalNanoseconds)
                self?.tick()
            }
        }
        defer { ticker.cancel() }

        while !Task.isCancelled {
            await poll()
            do {
                try await Task.sleep(nanoseconds: Self.pollIntervalSeconds * 1_000_000_000)
            } catch {
                return
            }
        }
    }

    /// Loads the network once: routes with colours, stops, stations and their
    /// joined coordinates (spec S2). A catalog without routes is an error:
    /// there is nothing to draw.
    func loadTopology() async {
        isLoading = true
        defer { isLoading = false }
        do {
            async let fetchedRoutes = client.routes()
            async let fetchedColors = client.lineTextColors()
            async let fetchedStops = client.allStops()
            async let fetchedStations = client.stations()
            let (loadedRoutes, loadedColors, loadedStops, loadedStations) =
                try await (fetchedRoutes, fetchedColors, fetchedStops, fetchedStations)

            let loadedLines = FGCNetwork.merge(routes: loadedRoutes, textColors: loadedColors)
            guard !loadedLines.isEmpty else {
                throw FGCError.unexpectedPayload("no routes")
            }
            let points = FGCNetwork.stopIndex(loadedStops)
            let joinedStations = FGCNetwork.stations(loadedStations, points: points)

            publishTopology(loadedLines, loadedStations: joinedStations, persist: true)
        } catch {
            // Spec S21: a failed topology load falls back to the cached copy,
            // so the lines, stations and live trains still render offline.
            if let cached = OfflineCache.loadFGCTopology() {
                publishTopology(cached.lines, loadedStations: cached.stations, persist: false)
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Publishes the loaded lines and stations and rebuilds everything derived
    /// from them (station names, geometry tables, drawable layers). `persist`
    /// is the network-success path recording the offline copy (spec S21), which
    /// is encoded and written off the main actor (spec S5); the cache fallback
    /// must not re-save what it just read.
    private func publishTopology(
        _ loadedLines: [FGCLine],
        loadedStations: [FGCStation],
        persist: Bool
    ) {
        if persist {
            OfflineCache.saveFGCTopology(lines: loadedLines, stations: loadedStations)
        }
        lines = loadedLines
        stations = loadedStations
        stationNamesByCode = FGCNetwork.stationNames(from: loadedStations)
        geometryByLine = Dictionary(
            uniqueKeysWithValues: loadedLines.map { ($0.code, FGCNetwork.geometry(polylines: $0.polylines)) }
        )
        lineLayers = loadedLines.map { line in
            MapLineLayer(
                id: line.code,
                operator: "FGC",
                code: line.code,
                colorHex: line.colorHex,
                textColorHex: line.textColorHex,
                polylines: line.polylines
            )
        }
        errorMessage = nil
    }

    /// Polls the live trains and re-anchors the glide (specs S3, S5). A failed
    /// poll keeps the previous trains and moves their markers on last data.
    func poll() async {
        guard !lines.isEmpty else { return }
        let start = pollClock.now
        do {
            let loaded = try await client.liveTrains(stationNames: stationNamesByCode)
            let now = Date()
            trains = loaded
            arrivalsUpdatedAt = now
            lastPollFailed = false
            anchorMotions(loaded, now: now)
            vehicles = publishedVehicles(now: now)
            addPollBreadcrumb("fgc trains", data: [
                "line": "fgc",
                "latency_ms": elapsedMilliseconds(since: start),
                "ok": true,
                "trains": loaded.count,
            ])
        } catch {
            lastPollFailed = true
            addPollBreadcrumb("fgc trains failed", data: [
                "line": "fgc",
                "latency_ms": elapsedMilliseconds(since: start),
                "ok": false,
                "trains": 0,
            ])
        }
    }

    /// Advances the glides by one tick. Called by the 10 Hz ticker in `run()`;
    /// does nothing before the first poll.
    func tick() {
        guard !motions.isEmpty else { return }
        vehicles = publishedVehicles(now: Date())
    }

    /// Records the new GPS points as glide targets. A train already on the
    /// same polyline starts from its current drawn distance; a new train, a
    /// line change or a point that no longer snaps starts at the target.
    private func anchorMotions(_ loaded: [FGCTrain], now: Date) {
        var next: [String: FGCMotion] = [:]
        next.reserveCapacity(loaded.count)
        for train in loaded {
            let style = FGCNetwork.style(for: train.lineCode, in: lines)
            if let geometry = geometryByLine[style.lineCode],
               let target = FGCNetwork.snap(train.position, in: geometry) {
                let previous = motions[train.id].flatMap { motion -> FGCMotion? in
                    motion.snapped && motion.polylineIndex == target.polylineIndex ? motion : nil
                }
                let start = previous.map { motion in
                    FGCNetwork.glide(
                        from: motion.startDistance,
                        to: motion.targetDistance,
                        elapsed: now.timeIntervalSince(motion.startedAt),
                        duration: TimeInterval(Self.pollIntervalSeconds)
                    )
                } ?? target.distance
                let reversed = FGCNetwork.travelHeading(
                    track: 0,
                    from: start,
                    to: target.distance,
                    previouslyReversed: previous?.reversed ?? false
                ).reversed
                next[train.id] = FGCMotion(
                    train: train,
                    lineCode: style.lineCode,
                    colorHex: style.colorHex,
                    snapped: true,
                    polylineIndex: target.polylineIndex,
                    startDistance: start,
                    targetDistance: target.distance,
                    reversed: reversed,
                    startedAt: now,
                    rawPosition: train.position,
                    rawHeading: target.heading
                )
            } else {
                next[train.id] = FGCMotion(
                    train: train,
                    lineCode: style.lineCode,
                    colorHex: style.colorHex,
                    snapped: false,
                    polylineIndex: -1,
                    startDistance: 0,
                    targetDistance: 0,
                    reversed: false,
                    startedAt: now,
                    rawPosition: train.position,
                    rawHeading: 0
                )
            }
        }
        motions = next
    }

    /// Draws every motion at `now`: snapped trains glide along their polyline
    /// and take the track bearing, raw ones stay at their GPS point (S5).
    /// Sorted by id so the map redraws deterministically.
    private func publishedVehicles(now: Date) -> [MapVehicle] {
        motions.values.compactMap { motion -> MapVehicle? in
            let label = motion.train.destinationName ?? motion.train.destinationCode
            if motion.snapped,
               let geometry = geometryByLine[motion.lineCode],
               motion.polylineIndex >= 0,
               motion.polylineIndex < geometry.polylines.count {
                let points = geometry.polylines[motion.polylineIndex]
                let cumulative = geometry.cumulative[motion.polylineIndex]
                let distance = FGCNetwork.glide(
                    from: motion.startDistance,
                    to: motion.targetDistance,
                    elapsed: now.timeIntervalSince(motion.startedAt),
                    duration: TimeInterval(Self.pollIntervalSeconds)
                )
                return MapVehicle(
                    id: motion.train.id,
                    lineCode: motion.lineCode,
                    colorHex: motion.colorHex,
                    position: GeoMath.point(at: distance, points: points, cumulative: cumulative) ?? motion.rawPosition,
                    heading: FGCNetwork.travelHeading(
                        track: FGCNetwork.heading(at: distance, points: points, cumulative: cumulative),
                        from: motion.startDistance,
                        to: motion.targetDistance,
                        previouslyReversed: motion.reversed
                    ).heading,
                    label: label
                )
            }
            return MapVehicle(
                id: motion.train.id,
                lineCode: motion.lineCode,
                colorHex: motion.colorHex,
                position: motion.rawPosition,
                heading: motion.rawHeading,
                label: label
            )
        }
        .sorted { $0.id < $1.id }
    }
}
