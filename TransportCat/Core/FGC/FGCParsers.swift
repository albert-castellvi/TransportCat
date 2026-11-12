import Foundation

/// Foundation-only parsers for the FGC open-data portal (specs S1-S3).
///
/// Every payload is the v2.1 records envelope (`{ "total_count", "results" }`)
/// decoded with `JSONSerialization`, the same tolerant path the TMB parsers
/// use. A record missing a required field is skipped: one malformed train must
/// never fail the whole poll.
enum FGCParser {
    /// The `results` array of a v2.1 records response.
    static func records(from data: Data) throws -> [[String: Any]] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let records = root["results"] as? [[String: Any]] else {
            throw FGCError.unexpectedPayload("missing results array")
        }
        return records
    }

    // MARK: - Routes

    /// `gtfs_routes` records into lines. The text colour is not part of this
    /// dataset: `FGCNetwork.merge` fills it from `lineas-red-fgc`.
    static func routes(from data: Data) throws -> [FGCLine] {
        routes(fromRecords: try records(from: data))
    }

    static func routes(fromRecords records: [[String: Any]]) -> [FGCLine] {
        records.compactMap { record in
            // An empty `route_short_name` is as missing as a null one, and
            // `JSONValue.string` returns `""` for it: the fallback is decided
            // on emptiness, not by a null-coalescing chain plus a later guard
            // that dropped the whole record.
            let candidates: [String?] = [
                JSONValue.string(from: record["route_short_name"]),
                JSONValue.string(from: record["route_id"]),
            ]
            guard let code = candidates.compactMap({ $0 }).first(where: { !$0.isEmpty }) else {
                return nil
            }
            return FGCLine(
                code: code,
                name: JSONValue.string(from: record["route_long_name"]) ?? code,
                colorHex: normalizeHex(JSONValue.string(from: record["route_color"])),
                textColorHex: "FFFFFF",
                polylines: polylines(from: record["shape"])
            )
        }
    }

    /// `lineas-red-fgc` records as `route_id -> route_text_color`.
    static func textColors(from data: Data) throws -> [String: String] {
        var result: [String: String] = [:]
        for record in try records(from: data) {
            guard let code = JSONValue.string(from: record["route_id"]),
                  let color = JSONValue.string(from: record["route_text_color"]) else {
                continue
            }
            result[code] = normalizeHex(color)
        }
        return result
    }

    /// GeoJSON `shape` (MultiLineString of [lon, lat] pairs) into polylines.
    /// Degenerate lines (fewer than two points) are dropped because they
    /// cannot be projected onto.
    private static func polylines(from shape: Any?) -> [[GeoPoint]] {
        guard let shape = JSONValue.dictionary(from: shape),
              let geometry = JSONValue.dictionary(from: shape["geometry"]),
              let coordinates = JSONValue.array(from: geometry["coordinates"]) else {
            return []
        }
        return coordinates.compactMap { line -> [GeoPoint]? in
            guard let line = JSONValue.array(from: line) else { return nil }
            let points = line.compactMap { pair -> GeoPoint? in
                guard let pair = JSONValue.array(from: pair), pair.count >= 2,
                      let longitude = JSONValue.double(from: pair[0]),
                      let latitude = JSONValue.double(from: pair[1]) else {
                    return nil
                }
                return GeoPoint(latitude: latitude, longitude: longitude)
            }
            return points.count >= 2 ? points : nil
        }
    }

    // MARK: - Stops

    /// One page of `gtfs_stops`.
    static func stops(from data: Data) throws -> [FGCStop] {
        stops(fromRecords: try records(from: data))
    }

    static func stops(fromRecords records: [[String: Any]]) -> [FGCStop] {
        records.compactMap { record in
            guard let id = JSONValue.string(from: record["stop_id"]), !id.isEmpty else {
                return nil
            }
            var point: GeoPoint?
            if let coordinates = JSONValue.dictionary(from: record["stop_coordinates"]),
               let latitude = JSONValue.double(from: coordinates["lat"]),
               let longitude = JSONValue.double(from: coordinates["lon"]) {
                point = GeoPoint(latitude: latitude, longitude: longitude)
            }
            return FGCStop(
                id: id,
                name: JSONValue.string(from: record["stop_name"]) ?? id,
                point: point,
                wheelchairBoarding: JSONValue.int(from: record["wheelchair_boarding"])
            )
        }
    }

    // MARK: - Stations

    /// One page of `codigo-estaciones`. Coordinates are not part of this
    /// dataset: `FGCNetwork.stations(_:points:)` joins them from the stops.
    static func stations(from data: Data) throws -> [FGCStation] {
        stations(fromRecords: try records(from: data))
    }

    static func stations(fromRecords records: [[String: Any]]) -> [FGCStation] {
        records.compactMap { record in
            guard let code = JSONValue.string(from: record["inicials"]), !code.isEmpty else {
                return nil
            }
            return FGCStation(
                code: code,
                name: JSONValue.string(from: record["nom_estacio"]) ?? code,
                networkLine: JSONValue.int(from: record["linia"]) ?? 0,
                order: JSONValue.int(from: record["ordre"]) ?? Int.max,
                point: nil
            )
        }
    }

    // MARK: - Live trains

    /// `posicionament-dels-trens` records into trains. `stationNames` resolves
    /// the `desti` code to a display name (spec S2); a missing name only
    /// leaves the destination code.
    static func trains(from data: Data, stationNames: [String: String] = [:]) throws -> [FGCTrain] {
        trains(fromRecords: try records(from: data), stationNames: stationNames)
    }

    static func trains(fromRecords records: [[String: Any]], stationNames: [String: String] = [:]) -> [FGCTrain] {
        records.compactMap { record in
            guard let id = JSONValue.string(from: record["id"]), !id.isEmpty,
                  let lineCode = JSONValue.string(from: record["lin"]), !lineCode.isEmpty,
                  let point = JSONValue.dictionary(from: record["geo_point_2d"]),
                  let latitude = JSONValue.double(from: point["lat"]),
                  let longitude = JSONValue.double(from: point["lon"]) else {
                return nil
            }

            let destinationCode = JSONValue.string(from: record["desti"]) ?? ""
            let stoppedAt = JSONValue.string(from: record["estacionat_a"])
            return FGCTrain(
                id: id,
                lineCode: lineCode,
                direction: JSONValue.string(from: record["dir"]) ?? "",
                originCode: JSONValue.string(from: record["origen"]) ?? "",
                destinationCode: destinationCode,
                destinationName: stationNames[destinationCode],
                position: GeoPoint(latitude: latitude, longitude: longitude),
                nextStopCodes: FGCNetwork.nextStopCodes(from: JSONValue.string(from: record["properes_parades"])),
                isOnTime: (JSONValue.string(from: record["en_hora"]) ?? "").caseInsensitiveCompare("True") == .orderedSame,
                stoppedAtStopCode: stoppedAt?.isEmpty == false ? stoppedAt : nil,
                unitType: JSONValue.string(from: record["tipus_unitat"]),
                occupancy: occupancy(from: record)
            )
        }
    }

    /// Cars of one train whose percentage the feed reports, in a stable order.
    private static func occupancy(from record: [String: Any]) -> [FGCCarOccupancy] {
        ["mi", "ri", "m1", "m2"].compactMap { car in
            guard let percent = JSONValue.int(from: record["ocupacio_\(car)_percent"]) else {
                return nil
            }
            return FGCCarOccupancy(car: car, percent: percent)
        }
    }

    private static func normalizeHex(_ hex: String?) -> String {
        (hex ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "#")).uppercased()
    }
}

/// Pure network rules of the FGC mode: aliases, stop-code joins, snapping and
/// gliding (specs S2, S4, S5). Kept free of I/O and state so they run in tests
/// without a network.
enum FGCNetwork {
    /// Live service codes that are runs of a base line (spec S4).
    static let aliases: [String: String] = [
        "R5R": "R5",
        "R6R": "R6",
        "R61": "R6",
        "R62": "R6",
    ]

    /// Colour of a live code with no route in `gtfs_routes` (today M1, M2).
    static let neutralColorHex = "8E8E93"
    static let neutralTextColorHex = "FFFFFF"

    /// A GPS point farther than this from its line is drawn raw (spec S5).
    static let maxSnapOffsetMeters = 300.0

    /// Base line of a live code: the alias target when it is one, the code
    /// itself otherwise.
    static func baseLineCode(for liveCode: String) -> String {
        aliases[liveCode] ?? liveCode
    }

    /// Colour, text colour and label of a live code (spec S4).
    static func style(for liveCode: String, in lines: [FGCLine]) -> FGCLineStyle {
        let base = baseLineCode(for: liveCode)
        guard let line = lines.first(where: { $0.code.caseInsensitiveCompare(base) == .orderedSame }) else {
            return FGCLineStyle(
                lineCode: base,
                colorHex: neutralColorHex,
                textColorHex: neutralTextColorHex,
                label: base
            )
        }
        return FGCLineStyle(
            lineCode: line.code,
            colorHex: line.colorHex.isEmpty ? neutralColorHex : line.colorHex,
            textColorHex: line.textColorHex.isEmpty ? neutralTextColorHex : line.textColorHex,
            label: line.code
        )
    }

    /// Applies the text colours from `lineas-red-fgc` to the parsed routes.
    /// A route absent from that dataset keeps white text.
    static func merge(routes: [FGCLine], textColors: [String: String]) -> [FGCLine] {
        routes.map { route in
            FGCLine(
                code: route.code,
                name: route.name,
                colorHex: route.colorHex,
                textColorHex: textColors[route.code] ?? "FFFFFF",
                polylines: route.polylines
            )
        }
    }

    /// Lines de-duplicated by code, keeping the first occurrence: a repeated
    /// code would publish two map layers with the same id, and the picker would
    /// show the line twice (#88).
    static func uniqueLines(_ lines: [FGCLine]) -> [FGCLine] {
        var seen: Set<String> = []
        return lines.filter { seen.insert($0.code).inserted }
    }

    // MARK: - Stop-code join (S2)

    /// The stop catalog read as a join source: coordinates per stop code
    /// (spec S2) plus the GTFS `wheelchair_boarding` per stop code (spec S17).
    /// Built once by `stopIndex` and consumed by `stations(_:points:)`.
    struct FGCStopIndex: Equatable {
        let points: [String: GeoPoint]
        let boarding: [String: Int]
    }

    /// Exact stop ids to their coordinates and boarding state. Platform rows
    /// (`GR1`...) are included; the station joins fall back to their prefix.
    static func stopIndex(_ stops: [FGCStop]) -> FGCStopIndex {
        var points: [String: GeoPoint] = [:]
        var boarding: [String: Int] = [:]
        for stop in stops {
            if let point = stop.point {
                points[stop.id] = point
            }
            if let state = stop.wheelchairBoarding {
                boarding[stop.id] = state
            }
        }
        return FGCStopIndex(points: points, boarding: boarding)
    }

    /// Coordinates of a station code: the stop whose id equals the code, or
    /// the first platform row that starts with it (`GR`, `GR1`... share
    /// coordinates). Only a digits-only remainder counts as a platform suffix:
    /// `GRX` is another stop, not a platform of `GR` (#87).
    static func stopPoint(for code: String, in stops: [FGCStop]) -> GeoPoint? {
        if let exact = stops.first(where: { $0.id == code }), let point = exact.point {
            return point
        }
        return stops
            .filter { isPlatformRow($0.id, of: code) }
            .sorted { $0.id < $1.id }
            .first { $0.point != nil }?
            .point
    }

    /// `wheelchair_boarding` of a station code (spec S17): the exact stop row
    /// wins; otherwise the alphabetically first platform row that starts with
    /// the code, so platform rows that disagree still join deterministically.
    static func boarding(for code: String, in index: FGCStopIndex) -> Int? {
        if let exact = index.boarding[code] { return exact }
        guard let key = index.boarding.keys
            .filter({ isPlatformRow($0, of: code) })
            .sorted()
            .first else { return nil }
        return index.boarding[key]
    }

    /// A platform row of `code`: the code followed only by digits (`GR1`).
    /// A bare prefix without that boundary addresses another stop (#87).
    private static func isPlatformRow(_ id: String, of code: String) -> Bool {
        guard id.hasPrefix(code) else { return false }
        let suffix = id.dropFirst(code.count)
        return !suffix.isEmpty && suffix.allSatisfy(\.isNumber)
    }

    /// Adds the station coordinates and boarding state joined from the stop
    /// catalog (S2, S17).
    static func stations(_ stations: [FGCStation], points index: FGCStopIndex) -> [FGCStation] {
        stations.map { station in
            FGCStation(
                code: station.code,
                name: station.name,
                networkLine: station.networkLine,
                order: station.order,
                point: point(for: station.code, in: index.points),
                wheelchairBoarding: boarding(for: station.code, in: index)
            )
        }
    }

    /// `codigo-estaciones` codes to their names, for resolving `desti`.
    static func stationNames(from stations: [FGCStation]) -> [String: String] {
        var result: [String: String] = [:]
        for station in stations {
            result[station.code] = station.name
        }
        return result
    }

    private static func point(for code: String, in points: [String: GeoPoint]) -> GeoPoint? {
        if let exact = points[code] { return exact }
        return points
            .filter { isPlatformRow($0.key, of: code) }
            .sorted { $0.key < $1.key }
            .first?
            .value
    }

    // MARK: - properes_parades (S3)

    /// Parses the semicolon-separated pseudo-JSON of `properes_parades`:
    /// `{"parada": "GR"};{"parada": "PR"}`. Each chunk is read on its own
    /// because the whole string is not valid JSON; a malformed chunk is
    /// ignored and the order of the feed is preserved.
    static func nextStopCodes(from raw: String?) -> [String] {
        guard let raw, !raw.isEmpty else { return [] }
        return raw.split(separator: ";").compactMap { chunk in
            guard let keyRange = chunk.range(of: "\"parada\"") else { return nil }
            let afterKey = chunk[keyRange.upperBound...]
            guard let colon = afterKey.firstIndex(of: ":") else { return nil }
            let afterColon = afterKey[afterKey.index(after: colon)...]
            guard let open = afterColon.firstIndex(of: "\"") else { return nil }
            let start = afterColon.index(after: open)
            guard let close = afterColon[start...].firstIndex(of: "\"") else { return nil }
            let code = String(afterColon[start..<close])
            return code.isEmpty ? nil : code
        }
    }

    // MARK: - Geometry, snapping and gliding (S5)

    /// Precomputes the cumulative distance tables of a line's polylines.
    static func geometry(polylines: [[GeoPoint]]) -> FGCLineGeometry {
        FGCLineGeometry(
            polylines: polylines,
            cumulative: polylines.map(GeoMath.cumulativeDistances)
        )
    }

    /// Projects a GPS point onto the nearest polyline. Returns nil when the
    /// nearest foot is farther than `maxOffsetMeters`: such a train is drawn
    /// raw instead of being snapped (spec S5).
    static func snap(
        _ point: GeoPoint,
        in geometry: FGCLineGeometry,
        maxOffsetMeters: Double = maxSnapOffsetMeters
    ) -> FGCProjection? {
        guard geometry.polylines.count == geometry.cumulative.count else { return nil }

        var bestIndex = -1
        var bestProjection: GeoMath.Projection?
        for index in geometry.polylines.indices {
            let polyline = geometry.polylines[index]
            guard polyline.count >= 2 else { continue }
            guard let projection = GeoMath.nearestProjection(
                of: point,
                in: polyline,
                cumulative: geometry.cumulative[index]
            ) else {
                continue
            }
            if let current = bestProjection, current.offsetMeters <= projection.offsetMeters {
                continue
            }
            bestProjection = projection
            bestIndex = index
        }

        guard let best = bestProjection, bestIndex >= 0, best.offsetMeters <= maxOffsetMeters else {
            return nil
        }
        let polyline = geometry.polylines[bestIndex]
        let cumulative = geometry.cumulative[bestIndex]
        return FGCProjection(
            polylineIndex: bestIndex,
            distance: best.distance,
            point: GeoMath.point(at: best.distance, points: polyline, cumulative: cumulative) ?? point,
            heading: heading(at: best.distance, points: polyline, cumulative: cumulative),
            offsetMeters: best.offsetMeters
        )
    }

    /// Bearing of the polyline segment that contains `distance`, i.e. the
    /// direction a train travels at that point. Out-of-range distances clamp
    /// to the first or last segment.
    static func heading(at distance: Double, points: [GeoPoint], cumulative: [Double]) -> Double {
        guard points.count >= 2, cumulative.count == points.count, let last = cumulative.last else {
            return 0
        }
        let clamped = min(max(distance, 0), last)
        var segment = points.count - 2
        for index in 0..<(points.count - 1) where cumulative[index + 1] >= clamped {
            segment = index
            break
        }
        return GeoMath.bearingDegrees(from: points[segment], to: points[segment + 1])
    }

    /// Direction a marker faces: the track bearing when the train moves toward
    /// higher polyline distances, the opposite bearing when it moves back along
    /// the drawn order, and the previous side when it did not move.
    static func travelHeading(
        track: Double,
        from start: Double,
        to target: Double,
        previouslyReversed: Bool
    ) -> (heading: Double, reversed: Bool) {
        let reversed = target == start ? previouslyReversed : target < start
        let heading = reversed ? (track + 180).truncatingRemainder(dividingBy: 360) : track
        return (heading, reversed)
    }

    /// Linear glide from `from` to `to` over `duration`: the value at a
    /// fraction of the poll interval, clamped to the interval so a late poll
    /// lands on the target instead of overshooting.
    static func glide(
        from start: Double,
        to target: Double,
        elapsed: TimeInterval,
        duration: TimeInterval
    ) -> Double {
        guard duration > 0 else { return target }
        let fraction = min(max(elapsed / duration, 0), 1)
        return start + (target - start) * fraction
    }
}
