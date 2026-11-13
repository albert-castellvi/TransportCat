import Foundation

/// One arrival row inside a nearby stop card (spec S10, mockup `V4Tot`):
/// the line badge values plus the two directions shown side by side.
struct NearbyLineRow: Identifiable, Equatable {
    /// Badge text: "L2", "H10", "S1".
    let lineLabel: String
    /// Line colour hex without "#".
    let colorHex: String
    /// Text colour hex without "#", or nil to derive it from the luminance.
    let textColorHex: String?
    /// First direction: destination and its countdown text.
    let firstDestination: String
    let firstTime: String
    /// Second direction; nil when the feed announced only one.
    let secondDestination: String?
    let secondTime: String?
    /// Per-arrival discriminator: FGC rows are one per train, so the line
    /// label alone is not unique (two trains of one line serve a station at the
    /// same time). The rows the feed groups per line leave it nil.
    var discriminator: String? = nil

    var id: String {
        guard let discriminator else { return lineLabel }
        return "\(lineLabel)|\(discriminator)"
    }
}

/// One stop card of "A prop teu" (spec S10): a place, its distance and the
/// next arrivals per line, ready for `NearbyStopsList`.
struct NearbyStopEntry: Identifiable, Equatable {
    let place: Place
    /// Straight-line distance from the user, in meters.
    let distanceMeters: Double
    /// Walking minutes the caption states (derived at the stated speed).
    let walkingMinutes: Int
    /// One row per line serving the stop, soonest direction first.
    let rows: [NearbyLineRow]

    var id: String { place.id }
}

/// Pure model of "A prop teu" (spec S10, T2): which stops to list, in which
/// order, and what each of their rows shows.
///
/// Foundation-only, no clock, no store and no SwiftUI, so the rules run in the
/// Linux harness. The speed constant is stated here because it decides the
/// sort: 80 m/min (4.8 km/h), the same flat walking speed
/// `ExploreFormatting.walkingSpeedMetersPerMinute` documents for the caption
/// of Explora — one speed for the whole app, never two.
///
/// Empty-arrival text: `EmptyArrivalText` is a convenience to decide the right
/// wording for an empty arrival section.
enum NearbyStops {

    // MARK: - Empty-arrival text

    /// The one wording for "this place answered and nothing is due", shared
    /// by the nearby cards and Explora's favourites (UX-13).
    // ponytail: no terminus wording. Telling "no bus ever leaves from here"
    // apart needs the stop's position in each direction, which these call
    // sites do not have; add it when a caller can pass it.
    static let noArrivalsText = String(localized: "Cap arribada prevista")

    /// Flat walking speed in meters per minute the walking minutes assume.
    static let walkingSpeedMetersPerMinute: Double = 80

    /// At most this many stop cards are listed (the mockup's short list; the
    /// same default `PlaceIndex.nearest` documents for Explora).
    static let maxStops = 10

    /// At most this many line rows per stop card.
    static let maxRowsPerStop = 4

    /// Walking minutes for a distance, rounded to the nearest minute with a
    /// floor of 1 for any non-zero distance. Same rule as
    /// `ExploreFormatting.walkingMinutes`, restated here so this module owns
    /// the constant its sort order is built on.
    static func walkingMinutes(meters: Double) -> Int {
        guard meters > 0 else { return 0 }
        return max(1, Int((meters / walkingSpeedMetersPerMinute).rounded()))
    }

    /// The nearby stop entries, sorted by walking time (i.e. distance — the
    /// speed is constant — but stated in the unit the rider reads), then by
    /// name, and capped at `maxStops`. Entries beyond `maxDistanceMeters` are
    /// dropped first; a nil user location yields an empty list, which is the
    /// "location denied / no fix yet" state the caller handles.
    ///
    /// - Parameters:
    ///   - userLocation: the rider's last fix, or nil when there is none.
    ///   - places: the place catalog (`PlaceCatalogStore.places`).
    ///   - maxDistanceMeters: radius a place must sit inside; `PlaceIndex`
    ///     documents the same 1 km default.
    static func entries(
        userLocation: GeoPoint?,
        places: [Place],
        maxDistanceMeters: Double = 1_000
    ) -> [NearbyStopEntry] {
        guard let userLocation else { return [] }
        return PlaceIndex.nearest(
            to: userLocation,
            places: places,
            limit: maxStops,
            maxDistance: maxDistanceMeters
        )
        .map { item in
            NearbyStopEntry(
                place: item.place,
                distanceMeters: item.distance,
                walkingMinutes: walkingMinutes(meters: item.distance),
                rows: []
            )
        }
    }

    /// Sorts and caps already-built entries (the caller attaches the arrivals
    /// rows first): distance in metres ascending, then name, then id so equal
    /// distances and equal names are still deterministic. Whole walking
    /// minutes hide the difference between 139 m and 173 m, so the metres are
    /// the sort key (#84). Entries already past `maxStops` are cut.
    static func sorted(_ entries: [NearbyStopEntry], maxStops: Int = NearbyStops.maxStops) -> [NearbyStopEntry] {
        entries
            .sorted { lhs, rhs in
                if lhs.distanceMeters != rhs.distanceMeters { return lhs.distanceMeters < rhs.distanceMeters }
                if lhs.place.name != rhs.place.name { return lhs.place.name < rhs.place.name }
                return lhs.place.id < rhs.place.id
            }
            .prefix(maxStops)
            .map { $0 }
    }

    /// The arrival rows of one stop card (spec S10): grouped by line, each row
    /// carrying up to two directions — soonest first — of that line's next
    /// arrivals. Metro arrivals are matched to a `MetroLine` for the badge;
    /// bus arrivals carry their own name and colour through `busLines`; FGC
    /// arrivals come from the shared state's trains, in feed order, and have
    /// no countdown (D1), so their time text is "ara" when a train is at or
    /// announcing the station.
    ///
    /// Rows are sorted by their soonest arrival, then by line label, before
    /// the cap: dictionary groups have no stable order, so the previous cap
    /// kept an arbitrary subset (#84). FGC rows carry no countdown and come
    /// last. Everything is derived from the values the existing fetchers
    /// publish; no new endpoint is called and no poller is modified (T2).
    static func lineRows(
        metroArrivals: [Arrival],
        busArrivals: [BusArrival],
        fgcArrivals: [FavoriteArrival],
        busLines: [BusLine]
    ) -> [NearbyLineRow] {
        // The build order is the last tie-break, so equal rows stay in feed
        // order instead of changing between launches.
        var rows: [(row: NearbyLineRow, seconds: Int, order: Int)] = []

        // Metro: group the arrivals of every line code, soonest two per line.
        let metroByLine = Dictionary(grouping: metroArrivals, by: \.lineCode)
        for (code, arrivals) in metroByLine {
            let line = MetroLine.allLines.first {
                $0.code == code || $0.displayName.caseInsensitiveCompare(code) == .orderedSame
            }
            let sorted = arrivals.sorted { ($0.seconds ?? .max) < ($1.seconds ?? .max) }
            let first = sorted.first, second = sorted.count > 1 ? sorted[1] : nil
            let order = rows.count
            rows.append((
                NearbyLineRow(
                    lineLabel: line?.displayName ?? code,
                    colorHex: line?.colorHex ?? "6B7280",
                    textColorHex: nil,
                    firstDestination: first?.destination ?? "—",
                    firstTime: first.map { Self.timeText(seconds: $0.seconds) } ?? "—",
                    secondDestination: second?.destination,
                    secondTime: second.map { Self.timeText(seconds: $0.seconds) }
                ),
                first?.seconds ?? Int.max,
                order
            ))
        }

        // Bus: the iBus feed answers with every line at the stop, in its own
        // space; group by line name ("H12") and colour from the catalog.
        let busByName = Dictionary(grouping: busArrivals, by: \.lineName)
        for (name, arrivals) in busByName {
            let catalogLine = busLines.first { $0.name == name }
            let sorted = arrivals.sorted { $0.seconds < $1.seconds }
            let first = sorted.first, second = sorted.count > 1 ? sorted[1] : nil
            let order = rows.count
            rows.append((
                NearbyLineRow(
                    lineLabel: name,
                    colorHex: catalogLine?.colorHex ?? "6B7280",
                    textColorHex: catalogLine?.textColorHex,
                    firstDestination: first?.destination ?? "—",
                    firstTime: first.map { ParadesTimeline.busTimeText(seconds: $0.seconds) } ?? "—",
                    secondDestination: second?.destination,
                    secondTime: second.map { ParadesTimeline.busTimeText(seconds: $0.seconds) }
                ),
                first?.seconds ?? Int.max,
                order
            ))
        }

        // FGC: read-only from the shared state's derived arrivals; no minutes
        // exist, so the time text is the status the Explora rows already use.
        // One row per train, so the train id keeps the identities apart.
        for arrival in fgcArrivals {
            let order = rows.count
            rows.append((
                NearbyLineRow(
                    lineLabel: arrival.lineLabel,
                    colorHex: arrival.colorHex,
                    textColorHex: arrival.textColorHex,
                    firstDestination: arrival.destination,
                    firstTime: arrival.status ?? "—",
                    secondDestination: nil,
                    secondTime: nil,
                    discriminator: arrival.id
                ),
                Int.max,
                order
            ))
        }

        return rows
            .sorted { lhs, rhs in
                if lhs.seconds != rhs.seconds { return lhs.seconds < rhs.seconds }
                if lhs.row.lineLabel != rhs.row.lineLabel { return lhs.row.lineLabel < rhs.row.lineLabel }
                return lhs.order < rhs.order
            }
            .prefix(maxRowsPerStop)
            .map { $0.row }
    }

    /// Countdown text of a metro arrival whose seconds are optional: nil means
    /// the feed gave no countdown, which reads as "—" exactly as the Parades
    /// row does.
    static func timeText(seconds: Int?) -> String {
        guard let seconds else { return "—" }
        if seconds <= ParadesTimeline.imminentThresholdSeconds { return String(localized: "ara") }
        return Arrival.countdownText(seconds: seconds)
    }
}
