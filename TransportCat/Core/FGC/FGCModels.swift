import Foundation

/// One FGC route as published by `gtfs_routes` (spec S1).
struct FGCLine: Equatable, Identifiable {
    /// `route_short_name` (or `route_id` when the former is empty): S1, R5...
    let code: String
    /// `route_long_name`, the human readable origin-destination description.
    let name: String
    /// `route_color`, uppercase hex without `#`.
    let colorHex: String
    /// `route_text_color` from `lineas-red-fgc`, uppercase hex without `#`.
    let textColorHex: String
    /// `shape` geometry, one entry per MultiLineString line. Empty when the
    /// route publishes no shape (live `L1` and `BusBV` today).
    let polylines: [[GeoPoint]]

    var id: String { code }
}

/// One row of the `gtfs_stops` catalog (spec S2).
struct FGCStop: Equatable, Identifiable {
    /// `stop_id`: the station code (`GR`) or a platform variant (`GR1`).
    let id: String
    let name: String
    /// `stop_coordinates`; nil when the row carries no usable coordinates.
    let point: GeoPoint?
    /// GTFS `wheelchair_boarding` (spec S17): 0 no information, 1 accessible,
    /// 2 not accessible; nil when the row does not carry the field.
    var wheelchairBoarding: Int? = nil
}

/// One row of `codigo-estaciones`: a station of one FGC network (spec S2).
struct FGCStation: Equatable, Identifiable {
    /// `inicials`, the code live trains use (`GR`).
    let code: String
    /// `nom_estacio`, the display name.
    let name: String
    /// `linia`: 1 for Barcelona-Vallès, 2 for Llobregat-Anoia. Not the route
    /// code (S1/R5...), which is why it is kept separately.
    let networkLine: Int
    /// `ordre`: position of the station inside its network line (spec S9).
    let order: Int
    /// Coordinates joined from the stop catalog, nil when no stop matches.
    let point: GeoPoint?
    /// GTFS `wheelchair_boarding` joined from the stop catalog (spec S17):
    /// 0 no information, 1 accessible, 2 not accessible; nil when no stop row
    /// carries it.
    var wheelchairBoarding: Int? = nil

    var id: String { code }
}

/// Occupancy of one car of a train, as the live feed reports it (spec S3).
struct FGCCarOccupancy: Equatable {
    /// Car suffix used by the feed: `mi`, `ri`, `m1`, `m2`.
    let car: String
    /// Percentage 0...100, nil when the feed reports no measurement.
    let percent: Int?
}

/// One live train of `posicionament-dels-trens` (spec S3).
struct FGCTrain: Equatable, Identifiable {
    /// Feed identity, stable across polls.
    let id: String
    /// Raw live `lin` code; aliases (R5R, R61...) are resolved by `FGCNetwork`.
    let lineCode: String
    /// `dir`: "A" or "D".
    let direction: String
    /// `origen` station code.
    let originCode: String
    /// `desti` station code.
    let destinationCode: String
    /// `desti` resolved to a station name through S2; nil when unknown.
    let destinationName: String?
    /// Raw GPS point (`geo_point_2d`).
    let position: GeoPoint
    /// `properes_parades` in feed order.
    let nextStopCodes: [String]
    /// `en_hora == "True"`.
    let isOnTime: Bool
    /// `estacionat_a`: a stop code, nil when the feed sends null. "NO" is a real
    /// stop (Sabadell Nord), not a "not stopped" marker.
    let stoppedAtStopCode: String?
    /// `tipus_unitat` (rolling stock family).
    let unitType: String?
    /// Per-car occupancy, only the cars whose percentage the feed reports.
    let occupancy: [FGCCarOccupancy]
}

/// Colour and label a live `lin` code is drawn with (spec S4).
struct FGCLineStyle: Equatable {
    /// Line code after alias resolution (R5R -> R5).
    let lineCode: String
    let colorHex: String
    let textColorHex: String
    /// Code the UI shows; the resolved base code, or the raw code when unknown.
    let label: String
}

/// A line's polylines plus their cumulative distance tables, precomputed once
/// per launch so the 10 Hz ticker never recomputes them (spec S5).
struct FGCLineGeometry: Equatable {
    let polylines: [[GeoPoint]]
    let cumulative: [[Double]]
}

/// A GPS point projected onto a line polyline (spec S5).
struct FGCProjection: Equatable {
    /// Index of the polyline the point projected onto.
    let polylineIndex: Int
    /// Distance along that polyline, in meters.
    let distance: Double
    /// Point on the polyline at `distance`.
    let point: GeoPoint
    /// Track direction at `point`, degrees clockwise from north.
    let heading: Double
    /// Perpendicular distance from the raw GPS point, in meters.
    let offsetMeters: Double
}

/// Errors of the FGC open-data client.
enum FGCError: Error, LocalizedError {
    case invalidURL
    case httpStatus(Int)
    case unexpectedPayload(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid FGC URL."
        case .httpStatus(let code):
            return "FGC responded with HTTP \(code)."
        case .unexpectedPayload(let reason):
            return "Unexpected FGC payload: \(reason)."
        }
    }
}
