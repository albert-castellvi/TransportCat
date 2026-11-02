import Foundation

/// Arrival fetching with a caller-chosen limit (spec S22).
///
/// `NextArrivalsFetcher` is the S15 dialog contract and caps every answer at
/// three arrivals, which is what a favorite row shows. The detail screen
/// shows the next five, so this provider repeats the same feeds with the same
/// clients and the same ordering rules and applies the limit the screen asks
/// for. It exists only on the watch and does not change the S15 contract.
enum WatchArrivalsProvider {
    /// Spec S22: the detail screen lists five arrivals.
    static let detailLimit = 5

    static func arrivals(
        for place: Place,
        client: TMBClient,
        fgcClient: FGCClient = FGCClient(),
        limit: Int,
        now: Date = Date()
    ) async -> [NextArrival] {
        guard limit > 0 else { return [] }

        switch place.kind {
        case .metroStation:
            guard let stationCode = Int(place.code) else { return [] }
            // i-Metro answers per line, so one request per serving line.
            var fetched: [Arrival] = []
            for lineCode in place.lineCodes {
                guard let arrivals = try? await client.metroArrivals(
                    lineCode: lineCode,
                    stationCodes: [stationCode]
                ) else { continue }
                fetched.append(contentsOf: arrivals[stationCode] ?? [])
            }
            return fetched
                .sorted { ($0.seconds ?? .max) < ($1.seconds ?? .max) }
                .prefix(limit)
                .map { arrival in
                    NextArrival(
                        line: arrival.lineCode,
                        destination: arrival.destination.isEmpty ? "—" : arrival.destination,
                        date: now.addingTimeInterval(TimeInterval(arrival.seconds ?? 0))
                    )
                }
        case .busStop:
            guard let stopCode = Int(place.code),
                  let arrivals = try? await client.busArrivals(stopCode: stopCode)
            else { return [] }
            return arrivals
                .sorted { $0.seconds < $1.seconds }
                .prefix(limit)
                .map { arrival in
                    NextArrival(
                        line: arrival.lineName,
                        destination: arrival.destination.isEmpty ? "—" : arrival.destination,
                        date: now.addingTimeInterval(TimeInterval(arrival.seconds))
                    )
                }
        case .fgcStation:
            // Station names so the row says "cap a Terrassa" instead of a
            // destination code; a failed catalog call leaves the codes.
            let names = (try? await fgcClient.stations()).map { FGCNetwork.stationNames(from: $0) } ?? [:]
            guard let trains = try? await fgcClient.liveTrains(stationNames: names) else { return [] }
            return trains
                .filter {
                    $0.stoppedAtStopCode == place.code || $0.nextStopCodes.contains(place.code)
                }
                .sorted {
                    NextArrivalsFetcher.rank($0, stationCode: place.code)
                        < NextArrivalsFetcher.rank($1, stationCode: place.code)
                }
                .prefix(limit)
                .map { train in
                    NextArrival(
                        line: FGCNetwork.baseLineCode(for: train.lineCode),
                        destination: train.destinationName ?? train.destinationCode,
                        date: now
                    )
                }
        }
    }
}
