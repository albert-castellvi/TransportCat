import Foundation

/// What the global map draws at a given camera zoom (spec S8).
///
/// Three levels, decided by a pure threshold on the visible latitude span so
/// the rule is testable without SwiftUI or MapKit:
/// - wider than 0.25°: `lines` only;
/// - 0.08° to 0.25°: `linesAndStations` adds the station dots;
/// - below 0.08°: `linesStationsAndVehicles` adds the vehicles with labels.
enum GlobalZoomLevel {
    /// Only the line polylines.
    case lines
    /// Lines plus the station dots.
    case linesAndStations
    /// Lines, stations, vehicles and vehicle labels.
    case linesStationsAndVehicles
}

extension GlobalZoomLevel {
    /// Whether the level draws station dots on top of the lines.
    var includesStations: Bool { self != .lines }

    /// Whether the level draws vehicles with their destination labels.
    var includesVehicles: Bool { self == .linesStationsAndVehicles }
}

/// The pure zoom rule behind `GlobalMapScreen` (spec S8).
enum GlobalZoom {
    /// Above this visible latitude span only the lines are drawn (spec S8).
    static let linesOnlyAboveDegrees: Double = 0.25

    /// Below this visible latitude span the vehicles and their labels join
    /// (spec S8). The band in between shows the station dots.
    static let vehiclesBelowDegrees: Double = 0.08

    /// Visible latitude span the global map opens with (spec S9). Above
    /// `linesOnlyAboveDegrees` on purpose, so the first paint is the
    /// lines-only band — no station dots until the rider zooms in, which then
    /// walks the ladder exactly as before (S8 bands unchanged).
    static let initialLatitudeSpan: Double = 0.30

    /// The detail level for a camera latitude span. The two edges (exactly
    /// 0.25 and exactly 0.08) belong to the station band: "wider than" and
    /// "below" are strict comparisons.
    static func level(forLatitudeSpan span: Double) -> GlobalZoomLevel {
        if span > linesOnlyAboveDegrees { return .lines }
        if span < vehiclesBelowDegrees { return .linesStationsAndVehicles }
        return .linesAndStations
    }

    /// Depth of a level in the zoom ladder: 0 for lines only, 2 for the full
    /// map. Lets callers assert that zooming in never removes detail.
    static func rank(of level: GlobalZoomLevel) -> Int {
        switch level {
        case .lines: return 0
        case .linesAndStations: return 1
        case .linesStationsAndVehicles: return 2
        }
    }
}
