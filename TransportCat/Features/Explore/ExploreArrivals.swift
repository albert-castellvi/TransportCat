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
    /// place, keyed by `Place.id`, plus the ids whose feed failed, so the row
    /// can tell a failed fetch from a stop with nothing due (#97). A place
    /// that was fetched and answered with nothing owns an empty key.
    @MainActor
    static func nextArrivals(
        for places: [Place],
        client: TMBClient,
        fgcState: FGCNetworkState,
        rodaliesState: RodaliesNetworkState,
        busLines: [BusLine]
    ) async -> (arrivals: [String: [FavoriteArrival]], failedPlaceIDs: Set<String>) {
        var result: [String: [FavoriteArrival]] = [:]
        var failed: Set<String> = []
        await addMetro(places: places, client: client, into: &result, failed: &failed)
        await addBus(places: places, client: client, busLines: busLines, into: &result, failed: &failed)
        addFGC(places: places, state: fgcState, into: &result)
        addRodalies(places: places, state: rodaliesState, into: &result)
        for place in places where result[place.id] == nil && !failed.contains(place.id) {
            result[place.id] = []
        }
        return (result, failed)
    }

    // MARK: - Metro

    /// One i-Metro request per line that serves a favorite station; the feed
    /// answers with every requested station at once. The places are asked as
    /// places: `TMBClient` bridges the catalog's `ID_ESTACIO` to the per-line
    /// `CODI_ESTACIO` the feed keys by, and answers under `Place.id` again.
    @MainActor
    private static func addMetro(
        places: [Place],
        client: TMBClient,
        into result: inout [String: [FavoriteArrival]],
        failed: inout Set<String>
    ) async {
        let metroPlaces = places.filter { $0.kind == .metroStation && Int($0.code) != nil }
        guard !metroPlaces.isEmpty else { return }

        // One request per line, asked with every favorite station at once.
        var placesByLine: [String: [Place]] = [:]
        for place in metroPlaces {
            for lineCode in place.lineCodes {
                placesByLine[lineCode, default: []].append(place)
            }
        }
        var arrivalsByPlace: [String: [Arrival]] = [:]
        for (lineCode, linePlaces) in placesByLine {
            guard let fetched = try? await client.metroArrivals(lineCode: lineCode, places: linePlaces)
            else {
                // The request covers every favorite station of this line.
                failed.formUnion(linePlaces.map(\.id))
                continue
            }
            for (id, arrivals) in fetched {
                arrivalsByPlace[id, default: []].append(contentsOf: arrivals)
            }
        }

        for place in metroPlaces {
            guard let arrivals = arrivalsByPlace[place.id], !arrivals.isEmpty else { continue }
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
        into result: inout [String: [FavoriteArrival]],
        failed: inout Set<String>
    ) async {
        for place in places where place.kind == .busStop {
            guard let code = Int(place.code) else { continue }
            guard let arrivals = try? await client.busArrivals(stopCode: code) else {
                failed.insert(place.id)
                continue
            }
            guard !arrivals.isEmpty else { continue }
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
                        status: train.isOnTime ? String(localized: "Puntual") : String(localized: "Amb retard"),
                        statusIsOnTime: train.isOnTime
                    )
                }
        }
    }

    // MARK: - Rodalies

    /// The next departures of a favorite Rodalies station, read from the shared
    /// timetable and the delays of the last poll. Pure state reading: whichever
    /// poller is alive owns the refresh — `RootView` under the Rodalies mode,
    /// the station sheet under the others — so this never starts a second one.
    /// A timetable that has not landed yet leaves the place without rows, which
    /// the row words as loading rather than as an empty board.
    @MainActor
    private static func addRodalies(
        places: [Place],
        state: RodaliesNetworkState,
        into result: inout [String: [FavoriteArrival]]
    ) {
        guard let schedule = state.schedule else { return }
        let now = Date()
        let timeZone = RodaliesDepartures.timeZone(of: schedule)
        for place in places where place.kind == .rodaliesStation {
            let board = state.nextDepartures(
                stationID: place.code,
                now: now,
                limit: ExploreFormatting.arrivalsPerPlace
            )
            guard !board.isEmpty else { continue }
            result[place.id] = board.map { departure in
                let line = state.lines.first { $0.code == departure.lineCode }
                let status = RodaliesDepartureText.delay(seconds: departure.delaySeconds)
                return FavoriteArrival(
                    id: departure.id,
                    lineLabel: departure.lineCode,
                    colorHex: line?.colorHex ?? FGCNetwork.neutralColorHex,
                    textColorHex: line?.textColorHex ?? FGCNetwork.neutralTextColorHex,
                    destination: departure.headsign,
                    countdown: RodaliesDepartureText.text(
                        until: departure.expectedAt,
                        now: now,
                        timeZone: timeZone
                    ),
                    // A timetable row says nothing about punctuality: the
                    // caption appears only when the feed knows the train.
                    status: status == .scheduled ? nil : status.text,
                    statusIsOnTime: status == .onTime
                )
            }
        }
    }
}
