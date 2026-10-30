import Foundation
import Observation
import OSLog
import Sentry

/// Monotonic clock for poll latency: wall-clock time would report nonsense
/// after an NTP step or a timezone change.
///
/// Same helper as `AppModel.swift`, duplicated because both files keep theirs
/// file-private: a poll either file performs must be measured the same way.
private let pollClock = ContinuousClock()

/// Milliseconds elapsed since `start`, truncated.
private func elapsedMilliseconds(since start: ContinuousClock.Instant) -> Int {
    let elapsed = pollClock.now - start
    let components = elapsed.components
    let milliseconds = Double(components.seconds) * 1_000
        + Double(components.attoseconds) / 1_000_000_000_000_000
    return Int(milliseconds)
}

/// Sentry breadcrumb for one bus poll (spec S5): category `poll`, with the
/// latency and counters that explain a slow or empty refresh. Breadcrumbs
/// only: a transient network failure stays out of the event stream.
private func addPollBreadcrumb(_ message: String, data: [String: Any]) {
    let crumb = Breadcrumb(level: .info, category: "poll")
    crumb.message = message
    crumb.data = data
    SentrySDK.addBreadcrumb(crumb)
}

/// State of the selected bus line: topology (loaded once) plus a polling cycle
/// of per-stop iBus arrivals that feeds the position engine (specs S4, S5, S9).
///
/// Bus real time is per stop, so unlike `LineState` a poll is many requests:
/// the evenly spaced subset `BusFleet.pollPlan` chooses, at most
/// `maxConcurrentRequests` in flight, every `pollIntervalSeconds`.
@MainActor
@Observable
final class BusLineState {
    let line: BusLine

    /// Directions of the line, sorted by `ID_SENTIT`; empty until loaded.
    private(set) var directions: [BusDirection] = []
    /// Buses on the map, sorted by id (spec S4).
    private(set) var positions: [BusPosition] = []
    /// Arrivals of THIS line at the polled stops of the last successful poll,
    /// grouped by stop code. All directions are included, so the stop sheet
    /// and the diagram read both from here.
    private(set) var arrivalsByStop: [Int: [BusArrival]] = [:]
    /// Time of the last successful poll; nil until one succeeds (spec S9).
    private(set) var arrivalsUpdatedAt: Date?
    /// Whether the last poll failed. A failed poll keeps the markers moving on
    /// the last known data, so it downgrades freshness instead of clearing it.
    private(set) var lastPollFailed = false
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    /// This line's timetable, loaded once in `loadTopology` (schedule S6). Nil
    /// when the bundle carries no pack or it has no entry for this line.
    private(set) var scheduleLine: ScheduleLine?
    /// Observations of the last successful poll, per bus: the stops it was seen
    /// approaching and the absolute instant the feed expects it there (poll
    /// time plus its countdown).
    private var observationsByBus: [Int: BusObservations] = [:]
    /// Estimated offset of each bus, computed once per poll from the
    /// observations above; empty when there is no timetable.
    private var delays: [Int: DelayEstimate] = [:]

    /// Poll cycle, in seconds. iBus updates on the order of tens of seconds,
    /// so 20 s keeps a line visible without hammering the API (spec S5).
    static let pollIntervalSeconds: UInt64 = 20
    /// Stop requests per poll, both directions together (spec S5).
    static let maxRequestsPerPoll = 30
    /// Stop requests allowed in flight at once.
    static let maxConcurrentRequests = 6

    private let client: TMBClient

    /// Smooth, per-direction movement between the 20 s polls. Not observed:
    /// only `positions`, the value they publish, drives the UI.
    @ObservationIgnored private var motions: [Int: TrainMotion] = [:]

    init(line: BusLine, client: TMBClient) {
        self.line = line
        self.client = client
    }

    /// Stops the poll actually asks about, counted once per stop code: the two
    /// directions share their terminals, and the strip says "N de M parades".
    var polledStopCount: Int {
        Set(directions.flatMap { $0.polledStops.map(\.code) }).count
    }

    /// Stops of the line, same counting rule as `polledStopCount`.
    var totalStopCount: Int {
        Set(directions.flatMap { $0.stops.map(\.code) }).count
    }

    /// Distinct buses the last successful poll reported for this line: what
    /// the data-source strip calls "K busos seguits" (spec S3).
    var trackedBusCount: Int {
        Set(arrivalsByStop.values.flatMap { $0 }.compactMap(\.busID)).count
    }

    /// A successful poll answered with no bus at all for the line: the screen
    /// says so instead of drawing an empty map (spec S9).
    var hasNoBuses: Bool {
        guard arrivalsUpdatedAt != nil, !lastPollFailed else { return false }
        return arrivalsByStop.values.allSatisfy(\.isEmpty)
    }

    /// Long-running task body: load topology once, then poll until cancelled
    /// (the bus screen's `.task` cancels on disappear, spec S5).
    func run() async {
        if directions.isEmpty {
            await loadTopology()
        }
        guard !directions.isEmpty else { return }
        // 10 Hz ticker between polls, like the metro line: the buses move
        // smoothly instead of hopping once per second.
        let ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
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

    /// Loads the line topology once: every stop of both directions and the
    /// route geometries, then builds the directions. A line whose stops cannot
    /// be projected onto its geometry reports an error instead of drawing a
    /// map without buses.
    func loadTopology() async {
        isLoading = true
        defer { isLoading = false }
        // The timetable is independent of the topology requests and a failure
        // to have one must not fail the screen (schedule S6).
        await loadScheduleLine()
        do {
            let loadedStops = try await client.busStops(lineCode: line.code)
            let loadedRoutes = try await client.busRoutes(lineCode: line.code)
            directions = BusFleet.directions(
                stops: loadedStops,
                routes: loadedRoutes,
                lineCode: String(line.code),
                maxRequests: Self.maxRequestsPerPoll
            )
            errorMessage = directions.isEmpty
                ? "No s'ha pogut projectar la línia sobre la seva geometria."
                : nil
            Self.log.info("Bus line \(self.line.name, privacy: .public): \(loadedStops.count) stops, \(self.directions.count) directions, \(self.polledStopCount) polled")
        } catch {
            Self.report(error, "stops", line: line.name)
            errorMessage = error.localizedDescription
        }
    }

    private static let log = Logger(subsystem: "cat.transport.app", category: "BusLineState")

    /// Loads this line's timetable: the store answers from its cache, or
    /// downloads this one line file, so neither the network nor the JSON
    /// decoding happens inside a screen update (schedule S8).
    ///
    /// The store comes from `AppModel.shared` because the screens build this
    /// state as `BusLineState(line:client:)`: without a timetable the property
    /// stays nil and every schedule feature degrades silently.
    private func loadScheduleLine() async {
        guard scheduleLine == nil else { return }
        scheduleLine = await AppModel.shared.schedule.line(mode: .bus, code: line.code)
    }

    /// Logs a failed request and reports it to Sentry as a non-fatal event, so
    /// a blank bus map in the field can be traced to its cause.
    private static func report(_ error: Error, _ request: String, line: String) {
        log.error("Bus line \(line, privacy: .public) \(request, privacy: .public) failed: \(SecretRedactor.redact(String(describing: error)), privacy: .public)")
        guard !error.isTransientNetworkFailure else { return }
        SentrySDK.capture(error: error) { scope in
            scope.setTag(value: request, key: "tmb.request")
            scope.setTag(value: line, key: "tmb.line")
        }
    }

    /// Polls every polled stop of the line and recomputes the bus positions.
    ///
    /// One failed stop request is skipped: another stop of the same bus is
    /// usually enough to place it. A poll where every request failed counts as
    /// a failed poll and changes nothing, so the markers keep moving on the
    /// last known data instead of being re-anchored to an empty feed.
    func poll() async {
        guard !directions.isEmpty else { return }
        let start = pollClock.now

        // One request per stop code: the two directions of a line share their
        // terminals, and asking twice for the same stop only burns budget.
        var requestedCodes: [Int] = []
        var seenCodes: Set<Int> = []
        for direction in directions {
            for stop in direction.polledStops where !seenCodes.contains(stop.code) {
                seenCodes.insert(stop.code)
                requestedCodes.append(stop.code)
            }
        }

        var responses: [(stopCode: Int, arrivals: [BusArrival]?, error: Error?)] = []
        let client = self.client
        for offset in stride(from: 0, to: requestedCodes.count, by: Self.maxConcurrentRequests) {
            let upper = min(offset + Self.maxConcurrentRequests, requestedCodes.count)
            let chunk = Array(requestedCodes[offset..<upper])
            let batch = await withTaskGroup(of: (stopCode: Int, arrivals: [BusArrival]?, error: Error?).self) { group in
                for code in chunk {
                    group.addTask {
                        do {
                            return (stopCode: code, arrivals: try await client.busArrivals(stopCode: code), error: nil)
                        } catch {
                            return (stopCode: code, arrivals: nil, error: error)
                        }
                    }
                }
                var results: [(stopCode: Int, arrivals: [BusArrival]?, error: Error?)] = []
                for await result in group {
                    results.append(result)
                }
                return results
            }
            responses.append(contentsOf: batch)
        }

        let succeeded = responses.filter { $0.arrivals != nil }
        guard !succeeded.isEmpty else {
            lastPollFailed = true
            if let error = responses.compactMap(\.error).first {
                Self.report(error, "arrivals", line: line.name)
            }
            addPollBreadcrumb("bus arrivals failed", data: [
                "line": line.name,
                "latency_ms": elapsedMilliseconds(since: start),
                "ok": false,
                "arrivals": 0,
                "buses": 0,
            ])
            return
        }

        var fetched: [Int: [BusArrival]] = [:]
        for response in succeeded {
            // iBus answers for every line at the stop; only this line's
            // arrivals belong to this state.
            let arrivals = (response.arrivals ?? []).filter { $0.lineCode == line.code }
            guard !arrivals.isEmpty else { continue }
            fetched[response.stopCode, default: []].append(contentsOf: arrivals)
        }
        arrivalsByStop = fetched
        arrivalsUpdatedAt = Date()
        lastPollFailed = false

        let now = Date()
        let all = fetched.values.flatMap { $0 }
        observationsByBus = Self.observations(from: fetched, now: now)
        delays = Self.estimates(for: observationsByBus, line: scheduleLine, now: now)
        let lineCode = String(line.code)
        for direction in directions {
            let trains = BusFleet.positions(direction: direction, arrivals: all, lineCode: lineCode).map(\.train)
            motions[direction.id, default: TrainMotion()].update(with: trains, now: now)
        }
        positions = publishedPositions(now: now)

        let buses = trackedBusCount
        addPollBreadcrumb("bus arrivals", data: [
            "line": line.name,
            "latency_ms": elapsedMilliseconds(since: start),
            "ok": true,
            "arrivals": all.count,
            "buses": buses,
        ])
        Self.log.info("Bus line \(self.line.name, privacy: .public): \(all.count) arrivals, \(buses) buses, \(self.positions.count) markers")
    }

    /// Estimated offset of one bus against the timetable, or nil when there is
    /// no timetable, the bus cannot be matched to a scheduled trip, or the
    /// match is too ambiguous to show (schedule S4, S6).
    ///
    /// Computed once per poll: the observations and the schedule work are the
    /// same for every bus, so the UI only reads the dictionary.
    func delay(forBus id: Int) -> DelayEstimate? {
        delays[id]
    }

    /// Live arrivals at a stop against the timetable of the same direction
    /// (schedule S6, S3). `directionID` is the iBus `id_sentit` the stop sheet
    /// and the diagram already use (1 = Anada).
    ///
    /// The iBus direction and the GTFS `direction_id` are different spaces (1/2
    /// against 0/1) and do not even agree in order, so the direction is matched
    /// by name: `DESTI_SENTIT` of the line direction against the headsign of the
    /// scheduled one, and, when the names differ, the only scheduled direction
    /// whose patterns serve the stop. Nil when neither identifies one.
    func regularity(stopCode: Int, directionID: Int, now: Date) -> RegularityReport? {
        guard let scheduleLine else { return nil }
        let destination = directions.first { $0.id == directionID }?.destinationName ?? ""
        guard let direction = scheduleLine.direction(headsign: destination, stopCodes: [stopCode]) else { return nil }
        let live = (arrivalsByStop[stopCode] ?? [])
            .filter { $0.directionID == directionID }
            .map { now.addingTimeInterval(Double($0.seconds)) }
        let scheduled = scheduleLine.arrivals(at: stopCode, directionID: direction.id, on: now)
        return Regularity.assess(live: live, scheduled: scheduled, now: now)
    }

    /// How old the arrivals behind the buses are (spec S9).
    func freshness(now: Date = Date()) -> DataFreshness {
        Freshness.level(
            lastUpdate: arrivalsUpdatedAt,
            now: now,
            lastAttemptFailed: lastPollFailed
        )
    }

    /// Advances the interpolated buses by one tick. Called by the 10 Hz ticker
    /// in `run()`; does nothing until the topology is loaded.
    func tick() {
        guard !directions.isEmpty else { return }
        positions = publishedPositions(now: Date())
    }

    /// Every direction's smoothed markers, wrapped as bus positions and sorted
    /// by id so the map redraws deterministically (spec S4).
    private func publishedPositions(now: Date) -> [BusPosition] {
        var result: [BusPosition] = []
        for direction in directions {
            guard var motion = motions[direction.id] else { continue }
            let trains = motion.advance(to: now, engine: direction.engine)
            motions[direction.id] = motion
            result.append(contentsOf: trains.map {
                BusPosition(id: "\(direction.id)-\($0.id)", directionID: direction.id, train: $0)
            })
        }
        return result.sorted { $0.id < $1.id }
    }

    /// Every polled stop the bus has an ETA for, as absolute instants: the feed
    /// answers with a countdown, and a countdown is only comparable with a
    /// timetable once it is anchored to the poll's own time.
    private static func observations(from fetched: [Int: [BusArrival]], now: Date) -> [Int: BusObservations] {
        var result: [Int: BusObservations] = [:]
        for (stopCode, arrivals) in fetched {
            for arrival in arrivals {
                guard let busID = arrival.busID else { continue }
                var observation = result[busID] ?? BusObservations(destination: arrival.destination)
                observation.stops.append((
                    stopCode: stopCode,
                    eta: now.addingTimeInterval(Double(arrival.seconds))
                ))
                result[busID] = observation
            }
        }
        return result
    }

    /// One estimate per bus of the poll, computed against the timetable of the
    /// scheduled direction its headsign (or, failing that, its observed stops)
    /// identifies. Buses that cannot be matched are simply absent.
    private static func estimates(
        for observations: [Int: BusObservations],
        line: ScheduleLine?,
        now: Date
    ) -> [Int: DelayEstimate] {
        guard let line else { return [:] }
        var result: [Int: DelayEstimate] = [:]
        for (busID, observed) in observations {
            guard let direction = line.direction(
                headsign: observed.destination,
                stopCodes: Set(observed.stops.map(\.stopCode))
            ) else { continue }
            guard let estimate = BusDelay.estimate(
                observations: observed.stops,
                line: line,
                directionID: direction.id,
                now: now
            ) else { continue }
            result[busID] = estimate
        }
        return result
    }
}

/// What the last poll saw of one bus: the stops it was heading to, the instant
/// the feed expects it there, and the destination that identifies its direction.
private struct BusObservations {
    var stops: [(stopCode: Int, eta: Date)] = []
    /// `desti_trajecte` of the arrival: the iBus name of the direction, which
    /// is what maps the bus onto a scheduled one.
    let destination: String
}
