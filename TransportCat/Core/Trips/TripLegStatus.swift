import Foundation

/// What the app honestly knows about one leg of an active trip (spec S4).
///
/// The rule is the same everywhere in the app: never invent a time. A leg
/// says what its operator's live source actually offers — a real countdown,
/// a timetable, live FGC train positions — and when the source has nothing
/// for the legs it falls back to the planner's own times (`planned`).
enum TripLegLive: Equatable {
    /// Departures at the leg's boarding stop, soonest first.
    ///
    /// `isRealTime` is true only when the departure carries a realtime
    /// adjustment. A Rodalies train the feed does not know yet is in the list
    /// but does not make it live: the time shown is the timetable.
    case departures([Date], isRealTime: Bool)
    /// FGC publishes no timetable: only where its trains are right now.
    case fgc(FGCLegLive)
    /// No live source for this leg (other operators, missing station ids):
    /// only the planner's planned time.
    case planned
}

/// Where the FGC trains that can serve a leg are, from the live positions.
struct FGCLegLive: Equatable {
    /// A train is stopped at the boarding station right now.
    let atPlatform: Bool
    /// Stops between the nearest approaching train and the boarding station
    /// in its announced next stops; nil when no train is approaching.
    let stopsAway: Int?
    /// Punctuality of the nearest train (the one at the platform, else the
    /// nearest approaching one); nil when no train serves the leg.
    let isOnTime: Bool?
    /// Trains that will stop at the boarding station and then at the
    /// destination, in that order.
    let trainCount: Int
}

/// Live status of one leg of an active trip.
struct TripLegStatus: Equatable {
    let legIndex: Int
    let live: TripLegLive
    /// Titles of the line's alerts in force while the trip is active.
    let alertTitles: [String]
    /// When this status was built (the last refresh); nil before the first.
    let updatedAt: Date?
}

/// Pure builders from the operators' live values to a leg's `TripLegLive`.
/// No networking and no clock of its own, so every rule is testable.
enum TripLegLiveBuilder {
    /// At most this many departures per leg: the pill shows the next one, and
    /// the rest is context.
    static let maxDepartures = 3

    // MARK: - Departures

    /// The soonest metro arrivals of the leg's direction.
    ///
    /// Arrivals are matched to the leg by destination (tolerant: case and
    /// diacritics ignored, contains either way); when none match the leg's
    /// headsign the full list is used, since a leg with no direction is no
    /// leg the rider can chase.
    static func metro(arrivals: [Arrival], headsign: String?, now: Date) -> TripLegLive {
        departures(
            arrivals.map { ($0.destination, $0.seconds.map(TimeInterval.init)) },
            headsign: headsign,
            now: now
        )
    }

    /// The soonest real-time bus arrivals of the leg's direction. iBus
    /// countdowns are live, so any kept departure is realtime.
    static func bus(arrivals: [BusArrival], headsign: String?, now: Date) -> TripLegLive {
        departures(
            arrivals.map { ($0.destination, TimeInterval($0.seconds)) },
            headsign: headsign,
            now: now
        )
    }

    /// The next Rodalies departures of the leg's line and direction.
    ///
    /// Times are the realtime-adjusted `expectedAt`; `isRealTime` is true only
    /// when at least one kept departure carries a delay. `direction` filters
    /// when the caller derived it from the timetable topology; `headsign`
    /// filters tolerantly on top of it.
    static func rodalies(
        departures: [RodaliesDeparture],
        lineCode: String,
        headsign: String?,
        direction: Int? = nil,
        now: Date
    ) -> TripLegLive {
        var kept = departures.filter { sameLine($0.lineCode, lineCode) }
        if let direction {
            let ofDirection = kept.filter { $0.direction == direction }
            if !ofDirection.isEmpty { kept = ofDirection }
        }
        if let headsign {
            let ofDirection = kept.filter { matches($0.headsign, headsign) }
            if !ofDirection.isEmpty { kept = ofDirection }
        }
        let soonest = kept
            .map(\.expectedAt)
            .filter { $0 >= now }
            .sorted()
            .prefix(maxDepartures)
        guard !soonest.isEmpty else { return .departures([], isRealTime: false) }
        return .departures(Array(soonest), isRealTime: soonest.contains { date in
            kept.contains { $0.expectedAt == date && $0.isRealtime }
        })
    }

    /// Shared direction filter and ordering of metro and bus arrivals:
    /// keep the leg's direction when any arrival matches, sort soonest first,
    /// keep the first `maxDepartures` and turn countdowns into absolute dates.
    /// Unknown countdowns (`nil`/negative) are dropped rather than guessed.
    private static func departures(
        _ arrivals: [(destination: String, seconds: TimeInterval?)],
        headsign: String?,
        now: Date
    ) -> TripLegLive {
        var kept = arrivals
        if let headsign {
            let matching = arrivals.filter { matches($0.destination, headsign) }
            if !matching.isEmpty { kept = matching }
        }
        let dates = kept
            .compactMap(\.seconds)
            .filter { $0 >= 0 }
            .sorted()
            .prefix(maxDepartures)
            .map { now.addingTimeInterval($0) }
        return .departures(Array(dates), isRealTime: true)
    }

    // MARK: - FGC

    /// Where the FGC trains that can serve the leg are right now.
    ///
    /// A train serves the leg when it is on the leg's line (in either code
    /// direction, aliases included) and its announced next stops contain the
    /// boarding station followed, later, by the destination — or when it is
    /// stopped at the boarding station and its next stops contain the
    /// destination. Trains running the opposite way never match.
    static func fgc(trains: [FGCTrain], lineCode: String, fromCode: String, toCode: String) -> TripLegLive {
        // Any train that stops at the boarding station and then at the
        // destination serves the rider, whatever its line: Gràcia → Sant Cugat
        // is served by S1 and S2 alike. `lineCode` stays in the signature for
        // the callers and documents the planned line.
        let serving = trains.filter { train in
            servesLeg(train, fromCode: fromCode, toCode: toCode)
        }
        if serving.isEmpty {
            return .fgc(FGCLegLive(atPlatform: false, stopsAway: nil, isOnTime: nil, trainCount: 0))
        }
        let atPlatform = serving.filter { $0.stoppedAtStopCode == fromCode }
        let approaching = serving.filter { train in
            guard let index = train.nextStopCodes.firstIndex(of: fromCode) else { return false }
            return toCode != fromCode && train.nextStopCodes[index...].contains(toCode)
        }
        let stopsAway = approaching
            .compactMap { $0.nextStopCodes.firstIndex(of: fromCode) }
            .min()
        let nearest = atPlatform
            .sorted { $0.destinationCode < $1.destinationCode }
            .first
            ?? approaching.sorted { left, right in
                let leftIndex = left.nextStopCodes.firstIndex(of: fromCode) ?? .max
                let rightIndex = right.nextStopCodes.firstIndex(of: fromCode) ?? .max
                if leftIndex != rightIndex { return leftIndex < rightIndex }
                return left.id < right.id
            }.first
        return .fgc(FGCLegLive(
            atPlatform: atPlatform.contains { $0.stoppedAtStopCode == fromCode },
            stopsAway: stopsAway,
            isOnTime: nearest?.isOnTime,
            trainCount: serving.count
        ))
    }

    /// Whether a train on its way is serving the leg: boarding station then
    /// destination, both still to come (a train stopped at the boarding
    /// station still lists it as its next stop).
    private static func servesLeg(_ train: FGCTrain, fromCode: String, toCode: String) -> Bool {
        if train.stoppedAtStopCode == fromCode {
            return train.nextStopCodes.contains(toCode)
        }
        guard let index = train.nextStopCodes.firstIndex(of: fromCode) else { return false }
        return toCode != fromCode && train.nextStopCodes[index...].contains(toCode)
    }

    // MARK: - Matching

    /// Case- and diacritics-insensitive "contains", either way round: a
    /// planner headsign often spells the feed destination in full ("Sabadell
    /// Parc Nord" / "Sabadell Parc N.").
    static func matches(_ lhs: String, _ rhs: String) -> Bool {
        let left = folded(lhs)
        let right = folded(rhs)
        guard !left.isEmpty, !right.isEmpty else { return false }
        return left.contains(right) || right.contains(left)
    }

    /// Whether two line codes name the same line, ignoring case ("r2n" /
    /// "R2N"). Exact otherwise: "11" is not "1".
    static func sameLine(_ lhs: String, _ rhs: String) -> Bool {
        lhs.caseInsensitiveCompare(rhs) == .orderedSame
    }

    private static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "ca"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The Catalan strings the trip card draws for one leg (spec S4). Pure, so
/// the honesty rules ("segons horari", FGC never a clock time) are testable.
enum TripLegWording {
    /// At or below this many seconds away, a real departure reads "ara".
    /// Same threshold as `ParadesTimeline`.
    static let imminentThresholdSeconds: TimeInterval = 60

    /// Beyond this many seconds away a countdown gives way to the wall clock.
    static let clockThresholdSeconds: TimeInterval = 60 * 60

    /// The big line and the small caption of a leg's card.
    struct Wording: Equatable {
        let big: String
        let small: String
    }

    /// The wording of a live status.
    static func wording(
        for live: TripLegLive,
        now: Date,
        plannedDeparture: Date?,
        timeZone: TimeZone = .current
    ) -> Wording {
        switch live {
        case .departures(let dates, let isRealTime):
            return departures(
                dates: dates,
                isRealTime: isRealTime,
                plannedDeparture: plannedDeparture,
                now: now,
                timeZone: timeZone
            )
        case .fgc(let fgc):
            return self.fgc(fgc)
        case .planned:
            return planned(departure: plannedDeparture, timeZone: timeZone)
        }
    }

    /// Realtime: "3 min" / "ara", then "després 7 i 11 min" (minutes until
    /// each, not clock times, so nothing is invented). Timetable: the clock
    /// time and "segons horari".
    static func departures(
        dates: [Date],
        isRealTime: Bool,
        plannedDeparture: Date?,
        now: Date,
        timeZone: TimeZone = .current
    ) -> Wording {
        guard let first = dates.min() else {
            // The feed answered with no train: the planner's time is all we
            // honestly have.
            return planned(departure: plannedDeparture, timeZone: timeZone)
        }
        guard isRealTime else {
            return Wording(big: clock(first, timeZone: timeZone), small: String(localized: "segons horari"))
        }
        let soonest = dates.sorted()
        let big = countdown(soonest[0], now: now, timeZone: timeZone)
        let rest = soonest.dropFirst().map { String(max(1, Int($0.timeIntervalSince(now) / 60))) }
        // "després 7 i 11 min": only the first keeps its unit, so the caption
        // fits a card; minutes, never a clock time.
        let small = rest.isEmpty
            ? String(localized: "seguiment en directe")
            : String(localized: "després \(rest.joined(separator: " i ")) min")
        return Wording(big: big, small: small)
    }

    /// FGC has no timetable: position wording only, never a clock time.
    static func fgc(_ live: FGCLegLive) -> Wording {
        if live.atPlatform {
            return Wording(
                big: String(localized: "Ja hi és"),
                small: live.isOnTime == false
                    ? String(localized: "a l'andana · amb retard")
                    : String(localized: "a l'andana · en hora")
            )
        }
        switch live.stopsAway {
        case .some(0):
            return Wording(
                big: String(localized: "arribant a l'andana"),
                small: onTimeCaption(live.isOnTime)
            )
        case .some(1):
            return Wording(
                big: String(localized: "a 1 parada"),
                small: onTimeCaption(live.isOnTime)
            )
        case .some(let stops):
            return Wording(
                big: String(localized: "a \(stops) parades"),
                small: onTimeCaption(live.isOnTime)
            )
        case nil:
            return Wording(big: "—", small: String(localized: "cap tren en directe"))
        }
    }

    /// No live source: the planner's departure and "segons planificació".
    static func planned(departure: Date?, timeZone: TimeZone = .current) -> Wording {
        guard let departure else {
            return Wording(big: "—", small: String(localized: "segons planificació"))
        }
        return Wording(big: clock(departure, timeZone: timeZone), small: String(localized: "segons planificació"))
    }

    // MARK: - Helpers

    /// "ara" within the imminent threshold, "N min" within the hour, the
    /// clock beyond: the same countdown rule as `RodaliesTimeText`, so the
    /// trip card and the station boards can never say it two ways.
    static func countdown(_ date: Date, now: Date, timeZone: TimeZone) -> String {
        let seconds = date.timeIntervalSince(now)
        if seconds <= imminentThresholdSeconds { return String(localized: "ara") }
        if seconds > clockThresholdSeconds { return clock(date, timeZone: timeZone) }
        return String(localized: "\(Int(seconds / 60)) min")
    }

    /// Wall clock "HH:mm" in the service's timezone, 24-hour and 0-padded for
    /// every locale: "10:46".
    static func clock(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private static func onTimeCaption(_ isOnTime: Bool?) -> String {
        isOnTime == false ? String(localized: "amb retard") : String(localized: "en hora")
    }
}
