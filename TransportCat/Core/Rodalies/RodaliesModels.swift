import Foundation

/// One line of the Rodalies de Catalunya nucleus (R1, R2N, RG1, RT2...).
///
/// Foundation only: the widget and the watch compile this file too, so nothing
/// here may import UIKit, SwiftUI or Observation.
struct RodaliesLine: Codable, Equatable, Identifiable {
    /// Short code the feed publishes after trimming, e.g. "R2N".
    let code: String
    /// Long name as the line's busiest route describes it, e.g.
    /// "Molins de Rei - Maçanet-Massanes".
    let name: String
    /// `route_color` from the feed, uppercase hex without `#`.
    let colorHex: String
    /// Colour of text drawn on `colorHex`, picked for contrast at build time.
    let textColorHex: String

    var id: String { code }
}

/// One station of the nucleus: a GTFS stop joined to the topology.
struct RodaliesStation: Codable, Equatable, Identifiable {
    /// GTFS `stop_id`, which is also the Generalitat's station id (`71801`).
    let id: String
    let name: String
    let latitude: Double
    let longitude: Double
    /// Line codes of the lines whose trips call here.
    let lineCodes: [String]
    /// GTFS `wheelchair_boarding`: 0 no information, 1 accessible, 2 not
    /// accessible. Nil when the stop row does not carry it.
    let wheelchairBoarding: Int?

    var point: GeoPoint { GeoPoint(latitude: latitude, longitude: longitude) }

    /// The three-state GTFS accessibility folded into a verdict: nil means the
    /// feed says nothing, which must not read as "not accessible".
    var isAccessible: Bool? {
        switch wheelchairBoarding {
        case 1: return true
        case 2: return false
        default: return nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case latitude = "lat"
        case longitude = "lon"
        case lineCodes = "lines"
        case wheelchairBoarding = "wheelchair"
    }
}

/// Ordered stations and drawn track of one line in one direction.
///
/// The feed has no `direction_id`; the pack derives direction 0/1 by projecting
/// each trip on the line's forward shape, so the pair (line, direction) is the
/// stable key the map, the sheet and the live trains share.
struct RodaliesDirection: Codable, Equatable, Identifiable {
    let lineCode: String
    /// 0 forward, 1 reverse, as the pack derived them from the shapes.
    let direction: Int
    /// Station ids in travel order for this direction.
    let stationIDs: [String]
    /// Drawn track, simplified at build time.
    let points: [GeoPoint]

    var id: String { "\(lineCode):\(direction)" }

    private enum CodingKeys: String, CodingKey {
        case lineCode = "line"
        case direction = "dir"
        case stationIDs = "stations"
        case points
    }

    /// The track travels as `[lat, lon]` pairs, which is a third of the bytes of
    /// named objects over thousands of points: the order is read here and
    /// written back the same way.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lineCode = try container.decode(String.self, forKey: .lineCode)
        direction = try container.decode(Int.self, forKey: .direction)
        stationIDs = try container.decode([String].self, forKey: .stationIDs)
        let pairs = try container.decode([[Double]].self, forKey: .points)
        points = pairs.compactMap { pair in
            guard pair.count >= 2 else { return nil }
            return GeoPoint(latitude: pair[0], longitude: pair[1])
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(lineCode, forKey: .lineCode)
        try container.encode(direction, forKey: .direction)
        try container.encode(stationIDs, forKey: .stationIDs)
        try container.encode(points.map { [$0.latitude, $0.longitude] }, forKey: .points)
    }
}

/// What the timetable knows about one trip, which is how a live vehicle is
/// joined to its line, its direction and its destination.
struct RodaliesTripInfo: Equatable {
    let lineCode: String
    let direction: Int
    let headsign: String
}

/// One live train, after the two realtime feeds and the timetable are joined.
struct RodaliesLiveTrain: Equatable, Identifiable {
    /// The vehicle id the feed publishes (Renfe's train number, `18122`).
    let id: String
    /// Line the trip belongs to; nil when its trip id names no known line.
    let lineCode: String
    /// Direction from the timetable, nil when the trip is not in today's pack.
    let direction: Int?
    /// Destination station name, nil when the pack does not know the trip.
    let headsign: String?
    /// Raw GPS fix.
    let position: GeoPoint
    /// Heading in degrees when the feed sends one; Renfe does not, so this is
    /// usually nil and the map takes the bearing from the line's track.
    let bearingDegrees: Double?
    /// Delay in seconds, negative when the train is early.
    let delaySeconds: Int?
    /// Timestamp of the GPS fix.
    let timestamp: Date?
    /// Stop the train is at or leaving, when the feed names it.
    let currentStopID: String?
    /// Next stop the feed reports.
    let nextStopID: String?
    /// GTFS-Realtime `currentStatus` (`INCOMING_AT`, `STOPPED_AT`...).
    let status: String?
}

/// One departure of a station's board.
struct RodaliesDeparture: Equatable, Identifiable {
    let tripID: String
    let lineCode: String
    let direction: Int
    /// Destination station name, as the rider reads it.
    let headsign: String
    /// The timetable's departure.
    let scheduledAt: Date
    /// Seconds of delay the realtime feed reports; nil means the board only
    /// has the timetable for this train.
    let delaySeconds: Int?

    /// Whether the time shown is realtime-adjusted (the feed knows this train)
    /// or the scheduled one.
    var isRealtime: Bool { delaySeconds != nil }

    /// The time the rider should plan with.
    var expectedAt: Date {
        guard let delaySeconds else { return scheduledAt }
        return scheduledAt.addingTimeInterval(TimeInterval(delaySeconds))
    }

    /// Same trip, same station, same service day.
    var id: String { "\(tripID)-\(lineCode)-\(Int(scheduledAt.timeIntervalSince1970))" }
}

/// The published timetable pack: per service date, per station, departures.
///
/// The file is large (the whole nucleus for every date of the feed), so its
/// rows are flat integer arrays over shared string tables instead of objects:
/// `[line, direction, seconds, headsign, trip]`, five integers per departure,
/// with `seconds` counting from the service day's midnight and free to pass
/// 86400 for the trains that leave after it.
///
/// A class, not a struct: the trip index is built once and memoised, and the
/// pack is immutable after decoding.
final class RodaliesSchedule {
    /// Width of one row in the flat arrays, in integers.
    static let rowWidth = 5
    /// Only version 1 exists; an unknown version is not decoded.
    static let supportedVersion = 1

    let timezone: String
    let lineCodes: [String]
    let headsigns: [String]
    let tripIDs: [String]
    /// Service dates present in the pack, as "yyyyMMdd", ascending.
    let dates: [String]
    /// date -> station id -> flat departure rows.
    let days: [String: [String: [Int]]]

    init(
        timezone: String,
        lineCodes: [String],
        headsigns: [String],
        tripIDs: [String],
        dates: [String],
        days: [String: [String: [Int]]]
    ) {
        self.timezone = timezone
        self.lineCodes = lineCodes
        self.headsigns = headsigns
        self.tripIDs = tripIDs
        self.dates = dates
        self.days = days
    }

    /// Decodes the JSON payload of the pack, or nil when it is not one this
    /// code understands. Every index in a row is bounds-checked when read, so a
    /// corrupt table degrades to a skipped row instead of a crash.
    static func decode(_ data: Data) -> RodaliesSchedule? {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.v == supportedVersion else { return nil }
        return RodaliesSchedule(
            timezone: payload.timezone,
            lineCodes: payload.lines,
            headsigns: payload.headsigns,
            tripIDs: payload.trips,
            dates: payload.dates,
            days: payload.days
        )
    }

    private struct Payload: Decodable {
        let v: Int
        let timezone: String
        let lines: [String]
        let headsigns: [String]
        let trips: [String]
        let dates: [String]
        let days: [String: [String: [Int]]]
    }

    // MARK: - Rows

    /// The departure rows of one station on one service date, as tuples.
    /// A malformed row is skipped; nothing here can trap.
    func rows(stationID: String, date: String) -> [(line: String, direction: Int, seconds: Int, headsign: String, tripID: String)] {
        guard let flat = days[date]?[stationID] else { return [] }
        var result: [(line: String, direction: Int, seconds: Int, headsign: String, tripID: String)] = []
        result.reserveCapacity(flat.count / Self.rowWidth)
        var index = 0
        while index + Self.rowWidth <= flat.count {
            let line = flat[index]
            let direction = flat[index + 1]
            let seconds = flat[index + 2]
            let headsign = flat[index + 3]
            let trip = flat[index + 4]
            index += Self.rowWidth
            guard line >= 0, line < lineCodes.count,
                  headsign >= 0, headsign < headsigns.count,
                  trip >= 0, trip < tripIDs.count else { continue }
            result.append((lineCodes[line], direction, seconds, headsigns[headsign], tripIDs[trip]))
        }
        return result
    }

    /// Trip id -> what the timetable knows about it, built once and reused by
    /// every live-train poll. The first date that mentions a trip wins; a trip
    /// belongs to one service date, so the answer cannot differ.
    func tripIndex() -> [String: RodaliesTripInfo] {
        if let cachedTripIndex { return cachedTripIndex }
        var index: [String: RodaliesTripInfo] = [:]
        index.reserveCapacity(tripIDs.count)
        for day in days.values {
            for flat in day.values {
                var position = 0
                while position + Self.rowWidth <= flat.count {
                    let line = flat[position]
                    let direction = flat[position + 1]
                    let headsign = flat[position + 3]
                    let trip = flat[position + 4]
                    position += Self.rowWidth
                    guard line >= 0, line < lineCodes.count,
                          headsign >= 0, headsign < headsigns.count,
                          trip >= 0, trip < tripIDs.count else { continue }
                    let tripID = tripIDs[trip]
                    if index[tripID] == nil {
                        index[tripID] = RodaliesTripInfo(
                            lineCode: lineCodes[line],
                            direction: direction,
                            headsign: headsigns[headsign]
                        )
                    }
                }
            }
        }
        cachedTripIndex = index
        return index
    }

    private var cachedTripIndex: [String: RodaliesTripInfo]?
}
