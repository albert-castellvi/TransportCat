import Foundation
import Observation

/// Motion bookkeeping of one train between two polls.
///
/// A train whose GPS point projects onto its line glides along the track for one
/// poll interval, so the marker moves instead of teleporting every 30 s; a train
/// that does not project (no fix near the track) is drawn at its raw point with
/// whatever bearing the feed gave, which is none today.
private struct RodaliesMotion {
    let train: RodaliesLiveTrain
    let lineCode: String
    let colorHex: String
    /// Precomputed geometry of the polyline the train glides on, nil when raw.
    let geometry: FGCLineGeometry?
    let startDistance: Double
    let targetDistance: Double
    let rawHeading: Double
    let startedAt: Date
}

/// State of the Rodalies de Catalunya mode: the bundled topology, the daily
/// timetable, and a 30 s poll of Renfe's two GTFS-Realtime feeds.
///
/// It publishes its drawable content as the shared `MapLineLayer`/`MapVehicle`
/// values, so the map layer draws Rodalies without knowing this class exists.
/// The timetable is only downloaded when the state runs, never at launch, and
/// the live trains are joined to it through the trip id.
@MainActor
@Observable
final class RodaliesNetworkState {
    static let shared = RodaliesNetworkState()

    /// The bundled network: lines, stations and per-direction geometry.
    private(set) var topology: RodaliesTopology?
    private(set) var lines: [RodaliesLine] = []
    private(set) var stations: [RodaliesStation] = []
    /// Live trains of the last successful poll, keyed by train number.
    private(set) var trains: [RodaliesLiveTrain] = []
    /// Drawable lines for the map.
    private(set) var lineLayers: [MapLineLayer] = []
    /// Smoothed trains; the UI filters by line.
    private(set) var vehicles: [MapVehicle] = []
    /// The timetable, once it has been downloaded or read from the cache.
    private(set) var schedule: RodaliesSchedule?
    /// Time of the last successful poll; nil until one succeeds.
    private(set) var arrivalsUpdatedAt: Date?
    /// Whether the last poll failed. A failed poll keeps the last markers
    /// moving, so it downgrades freshness instead of clearing the map.
    private(set) var lastPollFailed = false
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    /// Renfe regenerates the realtime feeds about every 20 s.
    static let pollIntervalSeconds: UInt64 = 30
    /// First pause before retrying a failed topology load, and the cap the delay
    /// doubles up to, like `FGCNetworkState`.
    static let topologyRetryInitialSeconds: UInt64 = 5
    static let topologyRetryMaxSeconds: UInt64 = 60
    /// 10 Hz ticker between polls, like `BusLineState.run()`.
    static let tickIntervalNanoseconds: UInt64 = 100_000_000
    /// Departures a station board asks for.
    static let departureLimit = 8

    private let client: RodaliesClient

    /// Line codes of the topology, the filter of every realtime poll.
    @ObservationIgnored private var knownLines: [String] = []
    /// "line:direction" -> precomputed geometry of that direction's track.
    @ObservationIgnored private var geometryByDirection: [String: FGCLineGeometry] = [:]
    /// Train number -> motion state. Not observed: `vehicles` is what the UI reads.
    @ObservationIgnored private var motions: [String: RodaliesMotion] = [:]
    /// trip_id -> line, direction and destination, from the timetable.
    @ObservationIgnored private var tripIndex: [String: RodaliesTripInfo] = [:]
    /// trip_id -> delay in seconds of the last successful trip-updates read.
    @ObservationIgnored private var delays: [String: Int] = [:]

    init(client: RodaliesClient = RodaliesClient()) {
        self.client = client
    }

    // MARK: - Lifecycle

    /// Long-running task body: load the topology, then the timetable, then poll
    /// until cancelled (the screen's `.task` cancels on disappear).
    func run() async {
        var retryDelay = Self.topologyRetryInitialSeconds
        while !Task.isCancelled && lines.isEmpty {
            loadTopology()
            guard lines.isEmpty, !Task.isCancelled else { break }
            do {
                try await Task.sleep(nanoseconds: retryDelay * 1_000_000_000)
            } catch {
                return
            }
            retryDelay = min(retryDelay * 2, Self.topologyRetryMaxSeconds)
        }
        guard !lines.isEmpty else { return }

        // The timetable is large and slow to decode: it loads off the main
        // actor while the first poll already runs, because the map and the
        // stations do not need it.
        let scheduleTask = Task { [weak self] in
            await self?.loadSchedule()
        }
        defer { scheduleTask.cancel() }

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

    /// Loads the bundled topology and rebuilds everything derived from it. The
    /// file ships inside the app, so there is no network and no offline copy to
    /// fall back to; a missing resource is a build mistake and says so.
    func loadTopology() {
        isLoading = true
        defer { isLoading = false }
        guard let loaded = RodaliesTopology.bundled else {
            errorMessage = String(localized: "No s'ha pogut carregar la xarxa de Rodalies.")
            return
        }
        publishTopology(loaded)
    }

    private func publishTopology(_ loaded: RodaliesTopology) {
        topology = loaded
        lines = loaded.lines
        stations = loaded.stations
        knownLines = loaded.lines.map(\.code)
        geometryByDirection = Dictionary(
            loaded.directions.map { direction in
                (direction.id, FGCNetwork.geometry(polylines: [direction.points]))
            },
            uniquingKeysWith: { first, _ in first }
        )
        lineLayers = loaded.lines.map { line in
            MapLineLayer(
                id: "rodalies-\(line.code)",
                operator: "Rodalies",
                code: line.code,
                colorHex: line.colorHex,
                textColorHex: line.textColorHex,
                polylines: drawnPolylines(for: line.code, in: loaded)
            )
        }
        errorMessage = nil
    }

    /// The track the map draws for a line: the forward direction, or the
    /// reverse one when the feed only has that.
    private func drawnPolylines(for code: String, in topology: RodaliesTopology) -> [[GeoPoint]] {
        if let forward = topology.direction(line: code, direction: 0), forward.points.count >= 2 {
            return [forward.points]
        }
        if let reverse = topology.direction(line: code, direction: 1), reverse.points.count >= 2 {
            return [reverse.points]
        }
        return []
    }

    /// Downloads (or reads from the cache) the timetable and indexes its trips.
    /// A failed load leaves `schedule` nil: the map still works and the station
    /// board simply has no timetable to show.
    func loadSchedule() async {
        let client = self.client
        let loaded = await Task.detached(priority: .utility) {
            await client.schedule()
        }.value
        guard let loaded else { return }
        schedule = loaded
        tripIndex = loaded.tripIndex()
    }

    // MARK: - Polling

    /// Reads both realtime feeds and republishes the trains. A failed poll keeps
    /// the previous trains moving on last data and only downgrades freshness.
    func poll() async {
        guard !lines.isEmpty else { return }
        do {
            async let positionsRequest = client.vehiclePositions()
            async let updatesRequest = client.tripUpdates()
            let (positionsData, updatesData) = try await (positionsRequest, updatesRequest)

            let positions = RodaliesParser.vehicles(from: positionsData, knownLines: knownLines)
            // A delay read that fails keeps the previous delays: a missing
            // delay is worse than a slightly old one for a rider waiting.
            let loadedDelays = RodaliesParser.tripDelays(from: updatesData, knownLines: knownLines)
            if !loadedDelays.isEmpty {
                delays = loadedDelays
            }
            let loaded = RodaliesParser.trains(from: positions, delays: delays, tripIndex: tripIndex)
            let now = Date()
            trains = loaded
            arrivalsUpdatedAt = now
            lastPollFailed = false
            anchorMotions(loaded, now: now)
            vehicles = publishedVehicles(now: now)
        } catch {
            lastPollFailed = true
        }
    }

    /// Advances the glides by one tick. Called by the 10 Hz ticker in `run()`;
    /// does nothing before the first poll.
    func tick() {
        guard !motions.isEmpty else { return }
        vehicles = publishedVehicles(now: Date())
    }

    // MARK: - Derived values

    /// Freshness of the live feed as the rider reads it.
    func freshness(now: Date = Date()) -> DataFreshness {
        Freshness.level(lastUpdate: arrivalsUpdatedAt, now: now, lastAttemptFailed: lastPollFailed)
    }

    /// The next departures of a station, with the delays of the last poll.
    func nextDepartures(stationID: String, now: Date = Date(), limit: Int = departureLimit) -> [RodaliesDeparture] {
        guard let schedule else { return [] }
        return RodaliesDepartures.nextDepartures(
            stationID: stationID,
            now: now,
            schedule: schedule,
            delays: delays,
            limit: limit
        )
    }

    /// Colour of a line, in the neutral grey the other operators use for a line
    /// they do not know.
    func colorHex(for lineCode: String) -> String {
        lines.first { $0.code == lineCode }?.colorHex ?? FGCNetwork.neutralColorHex
    }

    // MARK: - Motion

    /// Records the new GPS points as glide targets. A train already on the same
    /// polyline starts from its current drawn distance; a new train, a line
    /// change or a point that no longer snaps starts at the target.
    private func anchorMotions(_ loaded: [RodaliesLiveTrain], now: Date) {
        var next: [String: RodaliesMotion] = [:]
        next.reserveCapacity(loaded.count)
        for train in loaded {
            let colorHex = colorHex(for: train.lineCode)
            if let snapped = snap(train) {
                let previous = motions[train.id].flatMap { motion -> RodaliesMotion? in
                    motion.geometry?.polylines == snapped.geometry.polylines ? motion : nil
                }
                let start = previous.map { motion in
                    FGCNetwork.glide(
                        from: motion.startDistance,
                        to: motion.targetDistance,
                        elapsed: now.timeIntervalSince(motion.startedAt),
                        duration: TimeInterval(Self.pollIntervalSeconds)
                    )
                } ?? snapped.distance
                next[train.id] = RodaliesMotion(
                    train: train,
                    lineCode: train.lineCode,
                    colorHex: colorHex,
                    geometry: snapped.geometry,
                    startDistance: start,
                    targetDistance: snapped.distance,
                    rawHeading: snapped.heading,
                    startedAt: now
                )
            } else {
                next[train.id] = RodaliesMotion(
                    train: train,
                    lineCode: train.lineCode,
                    colorHex: colorHex,
                    geometry: nil,
                    startDistance: 0,
                    targetDistance: 0,
                    rawHeading: train.bearingDegrees ?? 0,
                    startedAt: now
                )
            }
        }
        motions = next
    }

    /// Projects a train onto the track of its direction, or onto both
    /// directions of its line when the timetable does not know the trip. Nil
    /// when no track is close enough, which means the train is drawn raw.
    private func snap(_ train: RodaliesLiveTrain) -> (geometry: FGCLineGeometry, distance: Double, heading: Double)? {
        var candidates: [String] = []
        if let direction = train.direction {
            candidates.append("\(train.lineCode):\(direction)")
        }
        candidates.append("\(train.lineCode):0")
        candidates.append("\(train.lineCode):1")

        var best: (geometry: FGCLineGeometry, projection: FGCProjection)?
        var seen: Set<String> = []
        for key in candidates where seen.insert(key).inserted {
            guard let geometry = geometryByDirection[key],
                  let projection = FGCNetwork.snap(train.position, in: geometry) else { continue }
            if let current = best, current.projection.offsetMeters <= projection.offsetMeters { continue }
            best = (geometry, projection)
        }
        guard let best else { return nil }
        return (best.geometry, best.projection.distance, best.projection.heading)
    }

    /// Draws every motion at `now`: snapped trains glide along their polyline
    /// and take the track bearing, raw ones stay at their GPS point. Sorted by
    /// id so the map redraws deterministically.
    private func publishedVehicles(now: Date) -> [MapVehicle] {
        motions.values.compactMap { motion -> MapVehicle? in
            let label = motion.train.headsign ?? motion.train.id
            guard let geometry = motion.geometry,
                  let points = geometry.polylines.first,
                  let cumulative = geometry.cumulative.first else {
                return MapVehicle(
                    id: "rodalies-\(motion.train.id)",
                    lineCode: motion.lineCode,
                    colorHex: motion.colorHex,
                    position: motion.train.position,
                    heading: motion.rawHeading,
                    label: label
                )
            }
            let distance = FGCNetwork.glide(
                from: motion.startDistance,
                to: motion.targetDistance,
                elapsed: now.timeIntervalSince(motion.startedAt),
                duration: TimeInterval(Self.pollIntervalSeconds)
            )
            guard let position = GeoMath.point(at: distance, points: points, cumulative: cumulative) else {
                return nil
            }
            return MapVehicle(
                id: "rodalies-\(motion.train.id)",
                lineCode: motion.lineCode,
                colorHex: motion.colorHex,
                position: position,
                heading: FGCNetwork.heading(at: distance, points: points, cumulative: cumulative),
                label: label
            )
        }
        .sorted { $0.id < $1.id }
    }
}
