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

    /// How far past a threshold the span must travel before the band changes
    /// (spec S8): a 4% margin on the crossed threshold, so a span wobbling
    /// around 0.25° or 0.08° cannot flip the band — and rebuild the whole map
    /// content — on every camera frame.
    static let hysteresisMargin: Double = 0.04

    /// The level for a camera latitude span with band hysteresis (spec S8):
    /// the band only changes once the span moves past the crossed threshold
    /// by `hysteresisMargin`; while the span stays inside that margin band,
    /// `previous` wins. Far from both thresholds this returns exactly what
    /// `level(forLatitudeSpan:)` returns, and a single large jump may cross
    /// two bands at once, like the plain function always did.
    static func level(forLatitudeSpan span: Double, previous: GlobalZoomLevel) -> GlobalZoomLevel {
        let linesExit = linesOnlyAboveDegrees * (1 - hysteresisMargin)
        let linesEnter = linesOnlyAboveDegrees * (1 + hysteresisMargin)
        let vehiclesEnter = vehiclesBelowDegrees * (1 - hysteresisMargin)
        let vehiclesExit = vehiclesBelowDegrees * (1 + hysteresisMargin)
        switch previous {
        case .lines:
            // Zooming in: keep the lines band until the span is a clear
            // margin below the station threshold.
            return span <= linesExit ? level(forLatitudeSpan: span) : .lines
        case .linesAndStations:
            if span > linesEnter { return .lines }
            if span < vehiclesEnter { return .linesStationsAndVehicles }
            return .linesAndStations
        case .linesStationsAndVehicles:
            // Zooming out: keep the vehicle band until the span is a clear
            // margin above the vehicle threshold.
            return span >= vehiclesExit ? level(forLatitudeSpan: span) : .linesStationsAndVehicles
        }
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

/// Pure camera-input rules of the global map that are not part of the zoom
/// ladder (spec S8): what the continuous camera callbacks may write to
/// `@State` without invalidating the whole map for no visible change.
enum GlobalCamera {
    /// Smallest heading change (degrees) worth storing: below it the marker
    /// counter-rotation is visually identical, and skipping the write keeps
    /// camera motion from re-diffing the map content.
    static let headingWriteThresholdDegrees: Double = 1

    /// Whether a heading change is large enough to store: the shortest way
    /// around the compass (0°–360° wraparound included) must reach the
    /// threshold.
    static func isHeadingChangeSignificant(from previous: Double, to next: Double) -> Bool {
        let difference = abs(next - previous).truncatingRemainder(dividingBy: 360)
        let shortest = min(difference, 360 - difference)
        return shortest >= headingWriteThresholdDegrees
    }
}
