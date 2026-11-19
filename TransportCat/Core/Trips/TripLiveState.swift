import Foundation
import Observation

/// Live state of the active trip (spec S4): per leg, the honest status a
/// normal rider needs, refreshed every 30 s while the trip is followed.
///
/// It fetches only what the trip's legs need and reuses the app's existing
/// sources — the shared `AppModel` (TMB client and metro/bus alerts),
/// `RodaliesNetworkState.shared` (timetable board with delays) and
/// `FGCNetworkState.shared` (live train positions) — instead of starting
/// second pollers. One failing source never blanks the others: a leg whose
/// fetch failed keeps its last status.
@MainActor
@Observable
final class TripLiveState {
    static let shared = TripLiveState()

    /// The active trip's statuses, one per ride leg in travel order.
    private(set) var statuses: [TripLegStatus] = []
    /// Phase of the trip at the last refresh.
    private(set) var phase: TripPhase = .arrived
    /// Arrival estimate: live for the first leg when it has a real
    /// departure, planned otherwise.
    private(set) var estimatedArrival: Date?
    private(set) var isLoading = false
    /// Message of the last refresh when nothing at all could be fetched;
    /// nil as soon as any pass succeeds.
    private(set) var lastError: String?

    /// Refresh period, the same as the FGC and Rodalies pollers.
    static let refreshIntervalSeconds: UInt64 = 30
    /// FGC train positions older than this are polled again before the legs
    /// are built: the state only polls when its screen runs.
    static let fgcStaleAfterSeconds: TimeInterval = 45
    /// Rodalies deps read from the board per station and line.
    static let rodaliesBoardLimit = 20

    private let alerts: @MainActor () -> ServiceAlertSnapshot
    private let fgcStaleAfter: TimeInterval
    /// `startedAt` and the trip of the running loop, kept for the phase.
    @ObservationIgnored private var activeTrip: SavedTrip?
    @ObservationIgnored private var startedAt: Date?
    /// Statuses of the previous pass by leg, to keep a failed leg's last
    /// answer instead of blanking it.
    @ObservationIgnored private var previous: [Int: TripLegStatus] = [:]

    /// `alerts` is the snapshot of the alerts in force, injectable for tests
    /// and previews; the app passes `AppModel.shared.snapshot()`.
    init(
        alerts: @escaping @MainActor () -> ServiceAlertSnapshot = { AppModel.shared.snapshot() },
        fgcStaleAfter: TimeInterval = fgcStaleAfterSeconds
    ) {
        self.alerts = alerts
        self.fgcStaleAfter = fgcStaleAfter
    }

    /// Long-running task body for the active trip (the card's `.task`
    /// cancels it when the trip stops being followed).
    ///
    /// `startedAt` is when the rider started following it; the planned
    /// timeline is built from there, so a trip followed at 08:00 for a ride
    /// at 10:00 keeps the planner's departure, while one started on the spot
    /// follows the live board as it moves.
    func run(trip: SavedTrip, startedAt: Date) async {
        if activeTrip != trip || self.startedAt != startedAt {
            previous = [:]
            statuses = []
        }
        activeTrip = trip
        self.startedAt = startedAt
        while !Task.isCancelled {
            await refresh()
            guard !Task.isCancelled else { return }
            do {
                try await Task.sleep(for: .seconds(Self.refreshIntervalSeconds))
            } catch {
                return
            }
        }
    }

    /// One refresh pass: fetch the sources the legs need, build the statuses,
    /// phase and arrival estimate, and publish them.
    func refresh() async {
        guard let trip = activeTrip, let startedAt else { return }
        isLoading = true
        defer { isLoading = false }

        let now = Date()
        let client = AppModel.shared.client
        let snapshot = alerts()
        let needsRodalies = trip.legs.contains { $0.operatorKind == .rodalies }
        let needsFGC = trip.legs.contains { $0.operatorKind == .fgc }
        // Credentials from the Info.plist, like the station sheet's fallback:
        // only trips with TMB legs ever need the client.
        let tmb = tmbClient(client)

        async let rodaliesReady = prepareRodalies(needs: needsRodalies)
        async let fgcReady = prepareFGC(needs: needsFGC)
        let (rodaliesOK, fgcOK) = await (rodaliesReady, fgcReady)

        // TMB legs: one arrivals request per (line, station) the trip boards,
        // metro and bus legs alike.
        var answers: [Int: LegAnswer] = [:]
        for (index, leg) in trip.legs.enumerated() {
            answers[index] = await fetchTMB(leg: leg, client: tmb, now: now)
        }
        let fetchFailures = answers.values.filter { if case .failed = $0 { return true } else { return false } }.count
            + (needsRodalies && !rodaliesOK ? 1 : 0)
            + (needsFGC && !fgcOK ? 1 : 0)

        var built: [Int: TripLegStatus] = [:]
        let rodaliesState = RodaliesNetworkState.shared
        let fgcState = FGCNetworkState.shared
        for (index, leg) in trip.legs.enumerated() {
            let titles = alertTitles(for: leg, snapshot: snapshot, now: now)
            let live: TripLegLive?
            switch leg.operatorKind {
            case .metro, .bus:
                live = answers[index]?.live
            case .rodalies:
                guard rodaliesOK,
                      rodaliesState.schedule != nil,
                      let from = leg.fromStationID else {
                    live = nil
                    break
                }
                let direction = rodaliesDirection(leg: leg, state: rodaliesState)
                let board = rodaliesState.nextDepartures(
                    stationID: from,
                    now: now,
                    limit: Self.rodaliesBoardLimit
                )
                live = TripLegLiveBuilder.rodalies(
                    departures: board,
                    lineCode: leg.lineCode,
                    headsign: leg.headsign,
                    direction: direction,
                    now: now
                )
            case .fgc:
                guard fgcOK, let from = leg.fromStationID, let to = leg.toStationID else {
                    live = nil
                    break
                }
                live = TripLegLiveBuilder.fgc(
                    trains: fgcState.trains,
                    lineCode: leg.lineCode,
                    fromCode: from,
                    toCode: to
                )
            case .other:
                live = TripLegLive.planned
            }
            let status = TripLegStatus(
                legIndex: index,
                live: live ?? previous[index]?.live ?? .planned,
                alertTitles: titles,
                updatedAt: live == nil ? previous[index]?.updatedAt : now
            )
            built[index] = status
        }

        previous = built
        statuses = trip.legs.indices.map { built[$0]! }

        let liveFirst = built[0].flatMap { realCatch(trip: trip, status: $0, startedAt: startedAt, now: now) }
        if let liveFirst {
            estimatedArrival = liveFirst + TimeInterval(trip.plannedDurationSeconds)
            phase = TripTiming.livePhase(trip: trip, firstDeparture: liveFirst, now: now)
        } else {
            estimatedArrival = TripTiming.plannedArrival(trip: trip, startedAt: startedAt)
            phase = TripTiming.plannedPhase(trip: trip, startedAt: startedAt, now: now)
        }
        lastError = (fetchFailures > 0 && built.values.allSatisfy { $0.updatedAt != now })
            ? String(localized: "No s'ha pogut actualitzar el trajecte. Torna-ho a provar.")
            : nil
    }

    // MARK: - Live departure of the first leg

    /// The first leg's departure that the rider can actually catch: a real
    /// departure (a countdown, a delay-adjusted time or a train about to
    /// arrive) when there is one, the planner's departure otherwise.
    private func realCatch(trip: SavedTrip, status: TripLegStatus, startedAt: Date, now: Date) -> Date? {
        let earliest = startedAt.addingTimeInterval(TimeInterval(trip.legs[0].walkSecondsBefore))
        let planned = TripTiming.plannedTimeline(trip: trip, startedAt: startedAt).departures.first
        switch status.live {
        case .departures(let dates, true):
            return TripTiming.nextCatchable(after: earliest, departures: dates)
                ?? TripTiming.nextCatchable(after: earliest, departures: dates, margin: 0)
                ?? planned
        case .departures, .planned:
            return planned
        case .fgc(let fgc) where fgc.atPlatform || (fgc.stopsAway ?? .max) <= 1:
            // The train is leaving now or next: the rider catches it if they
            // are already on their way there.
            return max(now, earliest)
        case .fgc:
            return planned
        }
    }

    // MARK: - Sources

    /// The app's TMB client, recreated from the Info.plist credentials when
    /// the model holds none yet (same fallback as the station sheet). Only a
    /// trip with TMB legs asks for it.
    private func tmbClient(_ client: TMBClient?) -> TMBClient? {
        client ?? (try? TMBClient.fromBundle())
    }

    /// Loads the Rodalies timetable if the state has none and polls the
    /// realtime delays. True when the schedule is available afterwards.
    private func prepareRodalies(needs: Bool) async -> Bool {
        guard needs else { return true }
        let state = RodaliesNetworkState.shared
        if state.schedule == nil {
            await state.loadSchedule()
        }
        await state.poll()
        return state.schedule != nil
    }

    /// Polls FGC trains when the state has none or stale ones; its trains are
    /// read directly afterwards, no second poller is started.
    private func prepareFGC(needs: Bool) async -> Bool {
        guard needs else { return true }
        let state = FGCNetworkState.shared
        let stale = state.arrivalsUpdatedAt.map { Date().timeIntervalSince($0) > fgcStaleAfter } ?? true
        if state.trains.isEmpty || stale {
            await state.poll()
        }
        return !state.trains.isEmpty
    }

    /// One leg's answer from the TMB feeds, or the failure that keeps the
    /// last status.
    enum LegAnswer {
        case success(TripLegLive)
        case failed

        var live: TripLegLive? {
            if case .success(let live) = self { return live }
            return nil
        }
    }

    private func fetchTMB(leg: SavedTripLeg, client: TMBClient?, now: Date) async -> LegAnswer {
        guard let client else { return .failed }
        switch leg.operatorKind {
        case .metro:
            guard let code = leg.fromStationID, let station = Int(code) else { return .success(.planned) }
            guard let arrivals = try? await client.metroArrivals(lineCode: leg.lineCode, stationCodes: [station]) else {
                return .failed
            }
            return .success(TripLegLiveBuilder.metro(arrivals: arrivals[station] ?? [], headsign: leg.headsign, now: now))
        case .bus:
            guard let code = leg.fromStationID, let stop = Int(code) else { return .success(.planned) }
            guard let arrivals = try? await client.busArrivals(stopCode: stop) else { return .failed }
            // iBus answers with every line of the stop; keep the leg's line
            // ("V15" or its numeric code).
            let lineCode = Int(leg.lineCode)
            let ofLine = arrivals.filter { arrival in
                TripLegLiveBuilder.sameLine(arrival.lineName, leg.lineCode)
                    || (lineCode != nil && arrival.lineCode == lineCode)
            }
            return .success(TripLegLiveBuilder.bus(arrivals: ofLine, headsign: leg.headsign, now: now))
        default:
            return .success(.planned)
        }
    }

    /// Direction of the leg from the timetable topology: the direction whose
    /// station order has the boarding station before the destination. Nil
    /// when the topology cannot tell, and the headsign alone filters.
    private func rodaliesDirection(leg: SavedTripLeg, state: RodaliesNetworkState) -> Int? {
        guard let from = leg.fromStationID, let to = leg.toStationID else { return nil }
        let matches = state.directions(ofLine: leg.lineCode).filter { direction in
            guard let start = direction.stationIDs.firstIndex(of: from),
                  let end = direction.stationIDs.firstIndex(of: to) else { return false }
            return start < end
        }
        return matches.count == 1 ? matches[0].direction : nil
    }

    /// Alerts in force for the leg's line, from the sources the app has:
    /// metro and TMB bus feeds; FGC and Rodalies publish no line alert feed
    /// to the app today, so those legs stay empty until one exists.
    private func alertTitles(for leg: SavedTripLeg, snapshot: ServiceAlertSnapshot, now: Date) -> [String] {
        let pool: [ServiceAlert]
        switch leg.operatorKind {
        case .metro:
            pool = snapshot.metro
        case .bus:
            pool = snapshot.bus
        default:
            return []
        }
        return pool
            .filter { alert in
                alert.lineCodes.contains { TripLegLiveBuilder.sameLine($0, leg.lineCode) }
            }
            .filter { $0.isActive(now: now) }
            .compactMap { AlertText.cleaned($0.text) }
    }
}

/// The alerts of the app in force right now, one array per TMB feed.
struct ServiceAlertSnapshot {
    let metro: [ServiceAlert]
    let bus: [ServiceAlert]
}

extension AppModel {
    /// Value snapshot of the alert feeds, so the trip state can be built and
    /// tested without holding the model.
    func snapshot() -> ServiceAlertSnapshot {
        ServiceAlertSnapshot(metro: alerts, bus: busAlerts)
    }
}

extension TripTiming {
    /// The phase of a live trip: the planner's phase, except that the first
    /// ride is judged against its real departure (`firstDeparture`) and each
    /// next ride against its cancelled-out planned time.
    static func livePhase(trip: SavedTrip, firstDeparture: Date, now: Date) -> TripPhase {
        guard !trip.legs.isEmpty else { return .arrived }
        let timeline = plannedTimeline(trip: trip, startedAt: firstDeparture)
        if now < firstDeparture { return .waiting(legIndex: 0) }
        for index in timeline.departures.indices {
            let starts = index == 0 ? firstDeparture : timeline.departures[index]
            if now < starts { return .transfer(toLegIndex: index) }
            if now < timeline.reaches[index] { return .riding(legIndex: index) }
        }
        return .arrived
    }
}
