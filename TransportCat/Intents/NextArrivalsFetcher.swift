import Foundation

/// The next arrivals of one place: line label, destination and expected date
/// (spec S15). Foundation-only on purpose — the future widget extension reuses
/// it unchanged, and the selection rules run in the Linux harness.
struct NextArrival: Hashable {
    /// Display code the dialogs speak: "L1", "H12", "S1".
    let line: String
    let destination: String
    /// Expected arrival; `now` when the feed announces no minutes (FGC).
    let date: Date
    /// Whether the feed announced the arrival without a countdown. The FGC
    /// open feed never sends minutes, so those arrivals mean "at the station
    /// now" and stop meaning it as soon as the data ages (see
    /// `ArrivalBoard.announcedLife`). Defaulted so callers that always have a
    /// countdown keep their initializer.
    var announcedWithoutCountdown: Bool = false
}

/// What one place answered.
enum NextArrivalsOutcome: Equatable {
    /// The feeds answered. `arrivals` is empty when nothing is coming, which
    /// is a fact the rider may rely on.
    case answered([NextArrival])
    /// No feed could be reached, so an empty list would be a lie.
    case unreachable

    var arrivals: [NextArrival] {
        switch self {
        case .answered(let arrivals): return arrivals
        case .unreachable: return []
        }
    }
}

/// Fetches the next arrivals of a `Place` (spec S15): metro through i-Metro
/// per serving line, bus through the per-stop iBus feed, and FGC through the
/// live-train open data. A failing feed yields no arrivals instead of an
/// error: a spoken "no arrivals" is a fine answer for Siri.
enum NextArrivalsFetcher {
    /// Contract S15: the dialog speaks at most three arrivals.
    static let maxArrivals = 3
    static let noArrivalsText = String(localized: "No hi ha arribades previstes ara mateix.")

    /// The arrivals of one place, without telling a failed feed from an empty
    /// one. The spoken and watch surfaces keep this shape: for them both mean
    /// "nothing to say".
    static func nextArrivals(
        for place: Place,
        client: TMBClient,
        fgcClient: FGCClient = FGCClient(),
        now: Date = Date(),
        limit: Int = maxArrivals
    ) async -> [NextArrival] {
        await outcome(
            for: place,
            client: client,
            fgcClient: fgcClient,
            now: now,
            limit: limit
        ).arrivals
    }

    /// The arrivals of one place, saying whether the feeds answered at all.
    /// The widget needs the difference: "no arribades" and "no s'ha pogut
    /// connectar" are different statements to a rider on a platform.
    static func outcome(
        for place: Place,
        client: TMBClient,
        fgcClient: FGCClient = FGCClient(),
        now: Date = Date(),
        limit: Int = maxArrivals
    ) async -> NextArrivalsOutcome {
        switch place.kind {
        case .metroStation:
            // The i-Metro feed answers per line; one request per line serving
            // the station, like the favorite rows of Explora do. The place is
            // asked as a place: the client bridges its `ID_ESTACIO` to the
            // per-line `CODI_ESTACIO` the feed keys by.
            guard !place.lineCodes.isEmpty else { return .answered([]) }
            var fetched: [Arrival] = []
            var answered = false
            for lineCode in place.lineCodes {
                guard let arrivals = try? await client.metroArrivals(
                    lineCode: lineCode,
                    places: [place]
                ) else { continue }
                answered = true
                fetched.append(contentsOf: arrivals[place.id] ?? [])
            }
            // Not one of the lines answered: the empty board would be our
            // silence, not the network's.
            guard answered else { return .unreachable }
            return .answered(metroSelection(fetched, now: now, limit: limit))
        case .busStop:
            guard let stopCode = Int(place.code) else { return .answered([]) }
            guard let arrivals = try? await client.busArrivals(stopCode: stopCode) else {
                return .unreachable
            }
            return .answered(busSelection(arrivals, now: now, limit: limit))
        case .fgcStation:
            // Station names so the dialog says "cap a Terrassa" instead of the
            // `desti` code; a failed catalog call leaves the codes.
            let names = (try? await fgcClient.stations()).map { FGCNetwork.stationNames(from: $0) } ?? [:]
            guard let trains = try? await fgcClient.liveTrains(stationNames: names) else {
                return .unreachable
            }
            return .answered(
                fgcSelection(trains, stationCode: place.code, now: now, limit: limit)
            )
        }
    }

    // MARK: - Pure selection

    /// Metro arrivals soonest first; a missing countdown sorts last and lands
    /// on `now`. At most `limit`: three for the spoken dialog, more for the
    /// widget, which groups them by line and direction.
    static func metroSelection(
        _ arrivals: [Arrival],
        now: Date,
        limit: Int = maxArrivals
    ) -> [NextArrival] {
        arrivals
            .sorted { ($0.seconds ?? .max) < ($1.seconds ?? .max) }
            .prefix(limit)
            .map { arrival in
                NextArrival(
                    line: arrival.lineCode,
                    destination: arrival.destination.isEmpty ? "—" : arrival.destination,
                    date: now.addingTimeInterval(TimeInterval(arrival.seconds ?? 0)),
                    announcedWithoutCountdown: arrival.seconds == nil
                )
            }
    }

    /// Bus arrivals soonest first, with the commercial line name.
    static func busSelection(
        _ arrivals: [BusArrival],
        now: Date,
        limit: Int = maxArrivals
    ) -> [NextArrival] {
        arrivals
            .sorted { $0.seconds < $1.seconds }
            .prefix(limit)
            .map { arrival in
                NextArrival(
                    line: arrival.lineName,
                    destination: arrival.destination.isEmpty ? "—" : arrival.destination,
                    date: now.addingTimeInterval(TimeInterval(arrival.seconds))
                )
            }
    }

    /// Trains stopped at the station first, then the ones announcing it in
    /// track order; the open feed has no minutes, so they read as arriving now
    /// and are flagged as announced without a countdown.
    static func fgcSelection(
        _ trains: [FGCTrain],
        stationCode: String,
        now: Date,
        limit: Int = maxArrivals
    ) -> [NextArrival] {
        trains
            .filter { $0.stoppedAtStopCode == stationCode || $0.nextStopCodes.contains(stationCode) }
            .sorted { rank($0, stationCode: stationCode) < rank($1, stationCode: stationCode) }
            .prefix(limit)
            .map { train in
                NextArrival(
                    line: FGCNetwork.baseLineCode(for: train.lineCode),
                    destination: train.destinationName ?? train.destinationCode,
                    date: now,
                    announcedWithoutCountdown: true
                )
            }
    }

    /// 0 for a train stopped at the station, else its index in
    /// `nextStopCodes` — smaller means closer.
    static func rank(_ train: FGCTrain, stationCode: String) -> Int {
        if train.stoppedAtStopCode == stationCode { return -1 }
        return train.nextStopCodes.firstIndex(of: stationCode) ?? 0
    }

    // MARK: - Dialog

    /// The spoken answer (spec S15): "Propers trens a Catalunya: L1 cap a
    /// Fondo en 2 min, …" — or `noArrivalsText` when the feeds are silent.
    static func dialog(for place: Place, arrivals: [NextArrival], now: Date) -> String {
        let soonest = Array(arrivals.prefix(maxArrivals))
        guard !soonest.isEmpty else { return noArrivalsText }
        let head = place.kind == .busStop
            ? String(localized: "Propers busos a")
            : String(localized: "Propers trens a")
        let items = soonest.map {
            String(localized: "\($0.line) cap a \($0.destination)\(timeSuffix(until: $0.date, now: now))")
        }
        return String(localized: "\(head) \(place.name): ") + items.joined(separator: ", ")
    }

    /// " en 2 min", rounded up; " ara mateix" when the feed carries no minutes
    /// or the arrival is already due.
    static func timeSuffix(until date: Date, now: Date) -> String {
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return String(localized: " ara mateix") }
        return String(localized: " en \(Int(ceil(seconds / 60))) min")
    }
}
