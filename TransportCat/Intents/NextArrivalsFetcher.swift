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
}

/// Fetches the next arrivals of a `Place` (spec S15): metro through i-Metro
/// per serving line, bus through the per-stop iBus feed, and FGC through the
/// live-train open data. A failing feed yields no arrivals instead of an
/// error: a spoken "no arrivals" is a fine answer for Siri.
enum NextArrivalsFetcher {
    /// Contract S15: the dialog speaks at most three arrivals.
    static let maxArrivals = 3
    static let noArrivalsText = "No hi ha arribades previstes ara mateix."

    static func nextArrivals(
        for place: Place,
        client: TMBClient,
        fgcClient: FGCClient = FGCClient(),
        now: Date = Date()
    ) async -> [NextArrival] {
        switch place.kind {
        case .metroStation:
            // The i-Metro feed answers per line; one request per line serving
            // the station, like the favorite rows of Explora do. The place is
            // asked as a place: the client bridges its `ID_ESTACIO` to the
            // per-line `CODI_ESTACIO` the feed keys by.
            var fetched: [Arrival] = []
            for lineCode in place.lineCodes {
                guard let arrivals = try? await client.metroArrivals(
                    lineCode: lineCode,
                    places: [place]
                ) else { continue }
                fetched.append(contentsOf: arrivals[place.id] ?? [])
            }
            return metroSelection(fetched, now: now)
        case .busStop:
            guard let stopCode = Int(place.code),
                  let arrivals = try? await client.busArrivals(stopCode: stopCode)
            else { return [] }
            return busSelection(arrivals, now: now)
        case .fgcStation:
            // Station names so the dialog says "cap a Terrassa" instead of the
            // `desti` code; a failed catalog call leaves the codes.
            let names = (try? await fgcClient.stations()).map { FGCNetwork.stationNames(from: $0) } ?? [:]
            guard let trains = try? await fgcClient.liveTrains(stationNames: names) else { return [] }
            return fgcSelection(trains, stationCode: place.code, now: now)
        }
    }

    // MARK: - Pure selection

    /// Metro arrivals soonest first; a missing countdown sorts last and lands
    /// on `now`. At most `maxArrivals`.
    static func metroSelection(_ arrivals: [Arrival], now: Date) -> [NextArrival] {
        arrivals
            .sorted { ($0.seconds ?? .max) < ($1.seconds ?? .max) }
            .prefix(maxArrivals)
            .map { arrival in
                NextArrival(
                    line: arrival.lineCode,
                    destination: arrival.destination.isEmpty ? "—" : arrival.destination,
                    date: now.addingTimeInterval(TimeInterval(arrival.seconds ?? 0))
                )
            }
    }

    /// Bus arrivals soonest first, with the commercial line name.
    static func busSelection(_ arrivals: [BusArrival], now: Date) -> [NextArrival] {
        arrivals
            .sorted { $0.seconds < $1.seconds }
            .prefix(maxArrivals)
            .map { arrival in
                NextArrival(
                    line: arrival.lineName,
                    destination: arrival.destination.isEmpty ? "—" : arrival.destination,
                    date: now.addingTimeInterval(TimeInterval(arrival.seconds))
                )
            }
    }

    /// Trains stopped at the station first, then the ones announcing it in
    /// track order; the open feed has no minutes, so they read as arriving now.
    static func fgcSelection(
        _ trains: [FGCTrain],
        stationCode: String,
        now: Date
    ) -> [NextArrival] {
        trains
            .filter { $0.stoppedAtStopCode == stationCode || $0.nextStopCodes.contains(stationCode) }
            .sorted { rank($0, stationCode: stationCode) < rank($1, stationCode: stationCode) }
            .prefix(maxArrivals)
            .map { train in
                NextArrival(
                    line: FGCNetwork.baseLineCode(for: train.lineCode),
                    destination: train.destinationName ?? train.destinationCode,
                    date: now
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
        let head = place.kind == .busStop ? "Propers busos a" : "Propers trens a"
        let items = soonest.map {
            "\($0.line) cap a \($0.destination)\(timeSuffix(until: $0.date, now: now))"
        }
        return "\(head) \(place.name): " + items.joined(separator: ", ")
    }

    /// " en 2 min", rounded up; " ara mateix" when the feed carries no minutes
    /// or the arrival is already due.
    static func timeSuffix(until date: Date, now: Date) -> String {
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return " ara mateix" }
        return " en \(Int(ceil(seconds / 60))) min"
    }
}
