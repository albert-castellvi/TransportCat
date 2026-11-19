import Foundation

/// The operator a saved leg belongs to (spec S4). It decides which live
/// source (T2) can follow the leg and how its stations are identified.
enum TripOperator: String, Codable {
    case metro
    case bus
    case fgc
    case rodalies
    case other
}

/// One ride of a saved trip, distilled from a planner `Leg` (spec S4).
///
/// A trip is saved as legs, never as frozen times: departure and arrival of a
/// saved trip are computed again every time it is used, and the legs keep only
/// what identifies the ride — operator, line, stations, headsign — plus the
/// walking time before it that the planned timeline needs.
struct SavedTripLeg: Codable, Hashable {
    let operatorKind: TripOperator
    /// The code the operator's screens use: metro `MetroLine.code` ("1", "91"
    /// for L9S), FGC "S1", Rodalies "R2N", bus "V15" / "A1".
    let lineCode: String
    /// The line as shown to riders: "L1", "S1", "R2N", "V15".
    let lineName: String
    /// Published line color without "#" (planner `routeColor`); nil when the
    /// feed sent none.
    let colorHex: String?
    let textColorHex: String?
    /// Destination announced on the vehicle ("Fondo").
    let headsign: String?
    let fromName: String
    let toName: String
    /// The station id the live sources use, when derivable from the planner
    /// stop: metro `CODI_ESTACIO` ("123"), FGC station code ("GR"), Rodalies
    /// GTFS stop id ("71801"), TMB bus `CODI_PARADA` ("319"). Nil for lines
    /// the app cannot follow (other operators, unknown shapes).
    let fromStationID: String?
    let toStationID: String?
    let fromPosition: GeoPoint
    let toPosition: GeoPoint
    /// Ride time of the leg, in seconds.
    let rideSeconds: Int
    /// Walking time of the walk legs between the previous ride (or the trip
    /// start) and this one, in seconds.
    let walkSecondsBefore: Int
    /// The planner leg geometry, used to draw the trip on the map.
    let geometry: [GeoPoint]
}

/// A trip picked from the planner and pinned on the maps (spec S4).
///
/// Saved trips are habitual, saved or recent. They hold the legs and the
/// endpoints to re-plan, but not the times: a stale trip re-plans from
/// `origin` to `destination` instead of promising a departure that is gone.
struct SavedTrip: Codable, Hashable, Identifiable {
    let id: UUID
    /// "Rocafort → Sant Cugat Centre" by default; the rider can rename it.
    let name: String
    let originName: String
    let destinationName: String
    /// Endpoints to re-plan the trip, as the planner received them.
    let origin: GeoPoint
    let destination: GeoPoint
    let kind: TripKind
    let createdAt: Date
    let lastUsedAt: Date?
    /// Rides only, in travel order.
    let legs: [SavedTripLeg]
    /// Walking after the last ride, in seconds.
    let finalWalkSeconds: Int
    /// Door-to-door time of the itinerary the trip was saved from.
    let plannedDurationSeconds: Int

    /// Stable identity for deduplication: same operators, lines and stations
    /// in the same order means the same trip, whatever its name or times.
    var signature: String {
        legs.map { "\($0.operatorKind.rawValue):\($0.lineCode):\($0.fromName)>\($0.toName)" }
            .joined(separator: "|")
    }

    /// Builds a trip from a planned itinerary, or nil when the itinerary has
    /// no transit leg (a walk-only plan is not a trip to follow).
    ///
    /// The endpoints are the caller's (the planner sheet's origin and
    /// destination, so a "current location" start keeps the planned
    /// coordinates); names fall back to the itinerary's first and last leg.
    init?(
        itinerary: Itinerary,
        originName: String,
        destinationName: String,
        origin: GeoPoint,
        destination: GeoPoint,
        kind: TripKind,
        now: Date,
        id: UUID = UUID()
    ) {
        let rides = itinerary.legs.filter { !$0.isWalk }
        guard !rides.isEmpty else { return nil }

        // Walking before a ride is the walk legs since the previous ride, and
        // it reads on the timeline as the wait before that ride.
        var walkSinceLastRide: TimeInterval = 0
        var legs: [SavedTripLeg] = []
        var finalWalkSeconds: TimeInterval = 0
        for leg in itinerary.legs {
            if leg.isWalk {
                walkSinceLastRide += leg.duration
                continue
            }
            legs.append(Self.savedLeg(from: leg, walkSecondsBefore: Int(walkSinceLastRide.rounded())))
            walkSinceLastRide = 0
            finalWalkSeconds = 0
        }
        finalWalkSeconds = walkSinceLastRide

        let name = "\(originName) → \(destinationName)"
        self.init(
            id: id,
            name: name,
            originName: originName,
            destinationName: destinationName,
            origin: origin,
            destination: destination,
            kind: kind,
            createdAt: now,
            lastUsedAt: nil,
            legs: legs,
            finalWalkSeconds: Int(finalWalkSeconds.rounded()),
            plannedDurationSeconds: Int(itinerary.duration.rounded())
        )
    }

    init(
        id: UUID = UUID(),
        name: String,
        originName: String,
        destinationName: String,
        origin: GeoPoint,
        destination: GeoPoint,
        kind: TripKind,
        createdAt: Date,
        lastUsedAt: Date? = nil,
        legs: [SavedTripLeg],
        finalWalkSeconds: Int,
        plannedDurationSeconds: Int
    ) {
        self.id = id
        self.name = name
        self.originName = originName
        self.destinationName = destinationName
        self.origin = origin
        self.destination = destination
        self.kind = kind
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.legs = legs
        self.finalWalkSeconds = finalWalkSeconds
        self.plannedDurationSeconds = plannedDurationSeconds
    }

    // MARK: - Mapping a planner leg

    private static func savedLeg(from leg: Leg, walkSecondsBefore: Int) -> SavedTripLeg {
        let operatorKind = operatorKind(agencyName: leg.agencyName, mode: leg.mode)
        let route = leg.route ?? ""
        let (lineCode, lineName) = line(for: operatorKind, route: route)
        return SavedTripLeg(
            operatorKind: operatorKind,
            lineCode: lineCode,
            lineName: lineName,
            colorHex: leg.routeColorHex,
            textColorHex: leg.routeTextColorHex,
            headsign: leg.headsign,
            fromName: leg.from.name,
            toName: leg.to.name,
            fromStationID: stationID(for: operatorKind, place: leg.from),
            toStationID: stationID(for: operatorKind, place: leg.to),
            fromPosition: leg.from.position,
            toPosition: leg.to.position,
            rideSeconds: Int(leg.duration.rounded()),
            walkSecondsBefore: walkSecondsBefore,
            geometry: leg.geometry
        )
    }

    /// Operator from the publisher and the OTP mode. Renfe and Rodalies are
    /// rail only; FGC runs rail in the planner; anything else the app cannot
    /// follow yet is `.other` and keeps whatever names the feed gave it.
    static func operatorKind(agencyName: String?, mode: String) -> TripOperator {
        let agency = agencyName ?? ""
        if agency.contains("Renfe") || agency.contains("Rodalies") {
            return .rodalies
        }
        if agency.uppercased().contains("FGC") {
            return .fgc
        }
        if agency.uppercased().contains("TMB") {
            if mode == "SUBWAY" || mode == "METRO" {
                return .metro
            }
            if mode == "BUS" {
                return .bus
            }
        }
        return .other
    }

    /// `(code, display name)` of the leg's line. Metro legs publish "L9S" and
    /// the app's screens use the numeric code "91", so the name resolves
    /// through `MetroLine` and the published name is the fallback.
    private static func line(for operatorKind: TripOperator, route: String) -> (String, String) {
        switch operatorKind {
        case .metro:
            if let line = MetroLine.allLines.first(where: { $0.displayName.caseInsensitiveCompare(route) == .orderedSame }) {
                return (line.code, line.displayName)
            }
            return (route, route)
        case .bus, .fgc, .rodalies:
            return (route, route)
        case .other:
            // Some bus feeds publish the line description as `route`; it has
            // no space in the code, so keep the first token as the code.
            let code = route.split(separator: " ").first.map(String.init) ?? route
            return (code, route.isEmpty ? code : route)
        }
    }

    /// Station id in the live source's shape, or nil when the stop does not
    /// follow the operator's documented pattern.
    static func stationID(for operatorKind: TripOperator, place: LegPlace) -> String? {
        switch operatorKind {
        case .metro:
            if let code = place.stopCode, !code.isEmpty {
                return code
            }
            // "3:1.123" → "123".
            return place.stopId?.split(separator: ".").last.map(String.init)
        case .fgc:
            // "2:GR1" → "GR": the namespace and the platform digit go.
            guard let stopId = place.stopId, let separator = stopId.firstIndex(of: ":") else {
                return nil
            }
            let code = stopId[stopId.index(after: separator)...]
            let station = String(code.prefix { !$0.isNumber })
            return station.isEmpty ? nil : station
        case .rodalies:
            // "4:71801" → "71801".
            guard let stopId = place.stopId, let separator = stopId.firstIndex(of: ":") else {
                return nil
            }
            let id = String(stopId[stopId.index(after: separator)...])
            return id.isEmpty ? nil : id
        case .bus:
            // "3:2.319.674897" → "319", the `CODI_PARADA` the iBus feed uses.
            guard let stopId = place.stopId, let separator = stopId.firstIndex(of: ":") else {
                return place.stopCode
            }
            let parts = stopId[stopId.index(after: separator)...].split(separator: ".")
            guard parts.count >= 2, parts.allSatisfy({ part in part.allSatisfy { $0.isNumber } }) else {
                return place.stopCode
            }
            return String(parts[1])
        case .other:
            return nil
        }
    }
}
