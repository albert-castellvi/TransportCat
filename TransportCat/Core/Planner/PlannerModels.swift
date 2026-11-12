import Foundation

/// Models of the TMB planner response (`DOC-TMB/planer.json`, spec S16).
///
/// They mirror the OpenTripPlanner schema the endpoint publishes: a plan holds
/// itineraries, an itinerary holds legs, and a leg runs `from` a place `to` a
/// place, with optional intermediate stops and an encoded geometry. Times come
/// back as epoch milliseconds and are converted on parse, so every model here
/// carries real `Date`s.
struct Itinerary: Hashable {
    /// Total door-to-door time, in seconds.
    let duration: TimeInterval
    let startTime: Date
    let endTime: Date
    /// Sum of the walking legs' time, in seconds.
    let walkTime: TimeInterval
    /// Re-chains between transit legs, as OTP counts them.
    let transfers: Int
    let legs: [Leg]

    var totalMinutes: Int { PlannerFormat.minutes(seconds: duration) }
    var walkMinutes: Int { PlannerFormat.minutes(seconds: walkTime) }
}

/// One leg of an itinerary: a walk or a ride on one line.
struct Leg: Hashable {
    let startTime: Date
    let endTime: Date
    /// OTP mode string: "WALK", "SUBWAY", "BUS", "TRAM", "RAIL", ...
    let mode: String
    /// Route short name ("L1", "7", "S1"); nil on walk legs.
    let route: String?
    let routeLongName: String?
    /// Published hex colors without "#", the `MetroLine.colorHex` shape.
    let routeColorHex: String?
    let routeTextColorHex: String?
    /// Destination announced on the vehicle ("Fondo").
    let headsign: String?
    let agencyName: String?
    /// Leg length in meters, when published.
    let distance: Double?
    let from: LegPlace
    let to: LegPlace
    /// Stops passed through without boarding changes; empty unless the
    /// request asked for them (it does) or the feed omitted the leg type.
    let intermediateStops: [LegStop]
    /// Decoded `legGeometry.points`, empty when the feed sent none.
    let geometry: [GeoPoint]
    let isTransit: Bool

    var isWalk: Bool { mode == "WALK" || !isTransit }
    var duration: TimeInterval { endTime.timeIntervalSince(startTime) }

    /// Badge text: the line's short name, falling back to the mode. Some bus
    /// legs publish the line description ("Districte Gran Via l'Hospitalet /
    /// Av. Esplugues") as `route`; a badge has room for a code only, so those
    /// fall back to the mode label until the bus catalog resolves them (#96).
    var badgeText: String {
        guard let route, !route.isEmpty, !route.contains(" "), route.count <= 5 else {
            return PlannerFormat.modeLabel(mode)
        }
        return route
    }
    /// Badge fill: the published route color, or a neutral gray when absent.
    var badgeColorHex: String { routeColorHex ?? "8E8E93" }
}

/// A leg endpoint: OTP's `from`/`to` place.
struct LegPlace: Hashable {
    let name: String
    let position: GeoPoint
}

/// One intermediate stop of a transit leg.
struct LegStop: Hashable {
    let name: String
    let code: String?
    let position: GeoPoint
}

/// Failures of the planner that the UI must word differently from a plain
/// network error (spec S16): "no route exists" reads differently from "the
/// calculation broke".
enum PlannerError: LocalizedError, Equatable {
    /// The graph answered with no itinerary (PATH_NOT_FOUND, NO_TRANSIT_TIMES,
    /// OUTSIDE_BOUNDS, TOO_CLOSE, the geocode failures ...).
    case noRoute
    /// Anything else that stopped a plan: a server error or a broken payload.
    case failed

    var errorDescription: String? {
        switch self {
        case .noRoute:
            return "No s'ha trobat cap ruta."
        case .failed:
            return "No s'ha pogut calcular la ruta. Torna-ho a provar."
        }
    }
}

/// Pure display logic of the planner screens (spec S16): rounding, Catalan
/// labels and time formatting, kept Foundation-only so it runs in the Linux
/// harness.
enum PlannerFormat {
    /// Whole minutes closest to `seconds` (4.5 min reads as 5).
    static func minutes(seconds: TimeInterval) -> Int {
        Int((seconds / 60).rounded())
    }

    static func totalLabel(seconds: TimeInterval) -> String {
        "\(minutes(seconds: seconds)) min"
    }

    static func walkingLabel(seconds: TimeInterval) -> String {
        "\(minutes(seconds: seconds)) min a peu"
    }

    static func transfersLabel(_ count: Int) -> String {
        switch count {
        case 0: return "Sense transbords"
        case 1: return "1 transbord"
        default: return "\(count) transbords"
        }
    }

    /// "8:05" — 24-hour, no padding on the hour, the way transit apps list.
    static func timeLabel(_ date: Date, timeZone: TimeZone = .autoupdatingCurrent) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%d:%02d", components.hour ?? 0, components.minute ?? 0)
    }

    static func timeRangeLabel(
        start: Date,
        end: Date,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        "\(timeLabel(start, timeZone: timeZone)) – \(timeLabel(end, timeZone: timeZone))"
    }

    /// Catalan name of an OTP mode; unknown modes keep the raw token.
    static func modeLabel(_ mode: String) -> String {
        switch mode {
        case "WALK": return "A peu"
        case "SUBWAY", "METRO": return "Metro"
        case "BUS": return "Bus"
        case "TRAM": return "Tramvia"
        case "RAIL": return "Tren"
        default: return mode
        }
    }

    /// Commercial name of the bus line whose description the planner published
    /// as a leg's route ("Districte Gran Via l'Hospitalet / Av. Esplugues" →
    /// "V1"). nil when the catalog does not know that description (#96).
    static func shortLineName(for route: String, in busLines: [BusLine]) -> String? {
        busLines.first {
            $0.description == route || "\($0.origin) / \($0.destination)" == route
        }?.name
    }
}

// MARK: - Current-location conflict resolution

/// Resolves the conflict when the rider picks "La meva ubicació" for one
/// endpoint but the other endpoint is also the current location. The explicit
/// choice is preserved, and the opposite endpoint is cleared so the two
/// never match (#96 remaining item).
///
/// - Parameters:
///   - existingOrigin: the current origin value.
///   - existingDestination: the current destination value.
///   - proposedEndpoint: the endpoint the rider just tapped.
///   - target: which endpoint the sheet was editing.
/// - Returns: a tuple `(origin, destination)` reflecting the rule.
///
/// Rule:
///   - If the proposed endpoint is current location and the *other*
///     endpoint is already current location → clear the other one.
///   - Otherwise → return the inputs unchanged.
func resolveCurrentLocationConflict(
    existingOrigin: PlannerEndpoint?,
    existingDestination: PlannerEndpoint?,
    proposedEndpoint: PlannerEndpoint,
    target: PlannerPickerTarget
) -> (origin: PlannerEndpoint?, destination: PlannerEndpoint?) {
    guard proposedEndpoint.isCurrentLocation else {
        // A manual place: no conflict.
        return (existingOrigin, existingDestination)
    }

    let otherIsCurrentLocation: Bool = {
        switch target {
        case .origin:
            return existingDestination?.isCurrentLocation ?? false
        case .destination:
            return existingOrigin?.isCurrentLocation ?? false
        }
    }()

    guard otherIsCurrentLocation else {
        // No conflict: the other endpoint is either nil or a manual place.
        // Let the caller update the target endpoint only.
        return (existingOrigin, existingDestination)
    }

    // Conflict: clear the opposite endpoint.
    switch target {
    case .origin:
        return (nil, existingDestination)
    case .destination:
        return (existingOrigin, nil)
    }
}
