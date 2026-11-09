import Foundation

/// One of the next arrivals of a favorite place (spec S12): metro and bus
/// carry a countdown, an FGC train carries a punctuality label instead — the
/// open-data feed announces no minutes.
struct FavoriteArrival: Identifiable, Hashable {
    let id: String
    /// Badge text: "L1", "H12", "S1".
    let lineLabel: String
    let colorHex: String
    /// nil lets the badge pick black or white from `HexLuminance`.
    let textColorHex: String?
    let destination: String
    /// "2 min" for metro and bus; nil for FGC.
    let countdown: String?
    /// "Puntual" / "Amb retard" for FGC; nil otherwise.
    let status: String?
    /// Whether `status` reads as on-time (drives its color).
    let statusIsOnTime: Bool?
}

/// Serializes the passes that refresh the favorites' arrivals (spec S12).
///
/// The screen refreshes from its 30 s loop and from a star or unstar, and both
/// passes are away in their network calls at the same time. A generation
/// counter makes the newest pass the owner of the snapshot: an older pass that
/// finishes later discards its answer instead of replacing a newer one that
/// already contains the place the rider just starred.
struct ArrivalRefreshGeneration {
    /// Generation of the newest pass; 0 before the first one.
    private(set) var current = 0

    /// Starts a pass and returns its generation.
    mutating func begin() -> Int {
        current += 1
        return current
    }

    /// Whether the pass still owns the snapshot: false once a newer pass began.
    func isCurrent(_ generation: Int) -> Bool {
        generation == current
    }
}

/// Fetches the next arrivals of the favorite places (spec S12): metro through
/// the existing `TMBClient.metroArrivals` in one call per line covering all
/// its favorite stations, bus through `busArrivals(stopCode:)` per stop, and
/// FGC read from `FGCNetworkState.shared.trains` whose next stops include the
/// station code — no second FGC poller is started here.
enum ExploreArrivals {
    /// At most `ExploreFormatting.arrivalsPerPlace` soonest arrivals per
    /// place, keyed by `Place.id`. A place whose feed failed or answered with
    /// nothing simply has no key, which the row shows as "Sense arribades".
    @MainActor
    static func nextArrivals(
        for places: [Place],
        client: TMBClient,
        fgcState: FGCNetworkState,
        busLines: [BusLine]
    ) async -> [String: [FavoriteArrival]] {
        var result: [String: [FavoriteArrival]] = [:]
        await addMetro(places: places, client: client, into: &result)
        await addBus(places: places, client: client, busLines: busLines, into: &result)
        addFGC(places: places, state: fgcState, into: &result)
        return result
    }

    // MARK: - Metro

    /// One i-Metro request per line that serves a favorite station; the feed
    /// answers with every requested station at once.
    @MainActor
    private static func addMetro(
        places: [Place],
        client: TMBClient,
        into result: inout [String: [FavoriteArrival]]
    ) async {
        let metroPlaces = places.filter { $0.kind == .metroStation && Int($0.code) != nil }
        guard !metroPlaces.isEmpty else { return }

        // One request per line, asked with every favorite station at once.
        var stationsByLine: [String: Set<Int>] = [:]
        for place in metroPlaces {
            guard let code = Int(place.code) else { continue }
            for lineCode in place.lineCodes {
                stationsByLine[lineCode, default: []].insert(code)
            }
        }
        var arrivalsByStation: [Int: [Arrival]] = [:]
        for (lineCode, codes) in stationsByLine {
            guard let fetched = try? await client.metroArrivals(lineCode: lineCode, stationCodes: Array(codes))
            else { continue }
            for (code, arrivals) in fetched {
                arrivalsByStation[code, default: []].append(contentsOf: arrivals)
            }
        }

        for place in metroPlaces {
            guard let code = Int(place.code),
                  let arrivals = arrivalsByStation[code], !arrivals.isEmpty else { continue }
            let soonest = arrivals
                .sorted { ($0.seconds ?? .max) < ($1.seconds ?? .max) }
                .prefix(ExploreFormatting.arrivalsPerPlace)
            result[place.id] = soonest.map { arrival in
                let line = metroLine(for: arrival.lineCode)
                return FavoriteArrival(
                    id: arrival.id,
                    lineLabel: line?.displayName ?? arrival.lineCode,
                    colorHex: line?.colorHex ?? "6B7280",
                    textColorHex: nil,
                    destination: arrival.destination.isEmpty ? "—" : arrival.destination,
                    countdown: arrival.rawText,
                    status: nil,
                    statusIsOnTime: nil
                )
            }
        }
    }

    /// The `MetroLine` a feed line code names, by API code ("1") or display
    /// name ("L1"); i-Metro answers with `nom_linia`, so both shapes arrive.
    private static func metroLine(for code: String) -> MetroLine? {
        MetroLine.allLines.first {
            $0.code == code || $0.displayName.caseInsensitiveCompare(code) == .orderedSame
        }
    }

    // MARK: - Bus

    /// One iBus request per favorite stop: the endpoint is already per stop and
    /// answers with every line that serves it.
    @MainActor
    private static func addBus(
        places: [Place],
        client: TMBClient,
        busLines: [BusLine],
        into result: inout [String: [FavoriteArrival]]
    ) async {
        for place in places where place.kind == .busStop {
            guard let code = Int(place.code),
                  let arrivals = try? await client.busArrivals(stopCode: code),
                  !arrivals.isEmpty else { continue }
            let soonest = arrivals
                .sorted { $0.seconds < $1.seconds }
                .prefix(ExploreFormatting.arrivalsPerPlace)
            result[place.id] = soonest.map { arrival in
                let catalogLine = busLines.first { $0.code == arrival.lineCode }
                return FavoriteArrival(
                    id: arrival.id,
                    lineLabel: arrival.lineName,
                    colorHex: catalogLine?.colorHex ?? "6B7280",
                    textColorHex: catalogLine?.textColorHex,
                    destination: arrival.destination.isEmpty ? "—" : arrival.destination,
                    countdown: Arrival.countdownText(seconds: arrival.seconds),
                    status: nil,
                    statusIsOnTime: nil
                )
            }
        }
    }

    // MARK: - FGC

    /// Trains of the shared state stopped at or announcing the station, in
    /// feed order. Pure state reading: whichever poller is alive owns the
    /// refresh — `RootView` under the FGC and global modes, `ExploreScreen`
    /// under the others — so this never starts a second one.
    @MainActor
    private static func addFGC(
        places: [Place],
        state: FGCNetworkState,
        into result: inout [String: [FavoriteArrival]]
    ) {
        guard !state.trains.isEmpty else { return }
        for place in places where place.kind == .fgcStation {
            let atStation = state.trains.filter {
                $0.stoppedAtStopCode == place.code || $0.nextStopCodes.contains(place.code)
            }
            guard !atStation.isEmpty else { continue }
            result[place.id] = atStation
                .prefix(ExploreFormatting.arrivalsPerPlace)
                .map { train in
                    let style = FGCNetwork.style(for: train.lineCode, in: state.lines)
                    return FavoriteArrival(
                        id: train.id,
                        lineLabel: style.label,
                        colorHex: style.colorHex,
                        textColorHex: style.textColorHex,
                        destination: train.destinationName ?? train.destinationCode,
                        countdown: nil,
                        status: train.isOnTime ? "Puntual" : "Amb retard",
                        statusIsOnTime: train.isOnTime
                    )
                }
        }
    }
}
