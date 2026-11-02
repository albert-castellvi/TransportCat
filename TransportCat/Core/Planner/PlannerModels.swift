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

    /// Badge text: the line's short name, falling back to the mode.
    var badgeText: String { route ?? PlannerFormat.modeLabel(mode) }
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
}
