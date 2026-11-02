import Foundation

/// Stations of one metro line, as returned by
/// `/transit/linies/metro/{code}/estacions` (spec S2).
struct TMBPlaceMetroLine {
    /// TMB `CODI_LINIA` ("1", "94").
    let code: String
    /// Display name ("L1", "L9N").
    let displayName: String
    let stations: [Station]
}

/// One physical bus stop of `/transit/parades` (spec S2). The all-network
/// endpoint carries geometry and names but no lines, which is why the per-line
/// feed is still needed.
struct TMBPlaceBusStop: Hashable {
    let code: Int
    let name: String
    let position: GeoPoint
}

/// Stops of one bus line, from `/transit/linies/bus/{code}/parades`, with the
/// commercial name that `Place.lineCodes` shows (spec S2).
struct TMBPlaceBusLineStops {
    /// TMB `CODI_LINIA` (212 for H12).
    let code: Int
    /// Commercial name ("H12").
    let name: String
    let stops: [BusStop]
}

/// Turns the TMB place endpoints into the shared `Place` model (spec S1, S2).
///
/// Pure over the decoded models: no networking, no clock, no location, so the
/// merge rules run in tests and in the Linux harness.
enum TMBPlaceParser {
    /// Distance under which an FGC station counts as served by a line. A
    /// station sits on its line's polyline, but the published shapes and the
    /// station point come from different datasets, so a few meters of slack are
    /// expected.
    static let fgcLineMatchMeters = 200.0

    // MARK: - Metro

    /// Every metro station once, with the lines that serve it and its
    /// accessibility (spec S2).
    ///
    /// TMB groups physical stations by name (`CODI_GRUP_ESTACIO` is not in the
    /// station payload ), so the name is the merge key, folded case- and
    /// diacritic-insensitively. The place code prefers `ID_ESTACIO` (stable
    /// across lines) and falls back to the per-line `CODI_ESTACIO`. A station
    /// is accessible only when every line that reports a state says it is.
    static func metroPlaces(from lines: [TMBPlaceMetroLine]) -> [Place] {
        struct Group {
            let name: String
            var code: String
            var position: GeoPoint
            var lineCodes: [String]
            var accessibility: [Bool]
        }

        var groups: [String: Group] = [:]
        for line in lines {
            for station in line.stations {
                let key = PlaceIndex.normalized(station.name)
                guard !key.isEmpty else { continue }
                let code = String(station.id ?? station.code)
                let position = GeoPoint(latitude: station.latitude, longitude: station.longitude)

                if var group = groups[key] {
                    if !group.lineCodes.contains(line.displayName) {
                        group.lineCodes.append(line.displayName)
                    }
                    if let accessible = station.accessible {
                        group.accessibility.append(accessible)
                    }
                    groups[key] = group
                } else {
                    groups[key] = Group(
                        name: station.name,
                        code: code,
                        position: position,
                        lineCodes: [line.displayName],
                        accessibility: station.accessible.map { [$0] } ?? []
                    )
                }
            }
        }

        return groups.values.map { group in
            let accessible: Bool?
            if group.accessibility.isEmpty {
                accessible = nil
            } else {
                accessible = group.accessibility.allSatisfy { $0 }
            }
            return Place(
                kind: .metroStation,
                code: group.code,
                name: group.name,
                position: group.position,
                lineCodes: group.lineCodes,
                accessible: accessible
            )
        }
        .sorted(by: placeOrder)
    }

    // MARK: - Bus

    /// Decodes `/transit/parades`, the all-network bus stop list.
    ///
    /// The endpoint is a GeoJSON FeatureCollection with `CODI_PARADA`,
    /// `NOM_PARADA` and the stop geometry; rows without a code, a name or a
    /// usable point are skipped.
    static func busNetworkStops(from data: Data) throws -> [TMBPlaceBusStop] {
        let root = try JSONSerialization.jsonObject(with: data)
        guard let dict = JSONValue.dictionary(from: root),
              let features = JSONValue.array(from: dict["features"]) else {
            throw TMBError.unexpectedPayload("missing features")
        }

        return features.compactMap { feature -> TMBPlaceBusStop? in
            guard let featureDict = JSONValue.dictionary(from: feature),
                  let properties = JSONValue.dictionary(from: featureDict["properties"]),
                  let code = JSONValue.int(from: properties["CODI_PARADA"]) else { return nil }
            let name = JSONValue.string(from: properties["NOM_PARADA"])
                ?? JSONValue.string(from: properties["DESC_PARADA"])
                ?? String(code)
            guard let geometry = JSONValue.dictionary(from: featureDict["geometry"]),
                  let coordinates = JSONValue.array(from: geometry["coordinates"]),
                  coordinates.count >= 2,
                  let longitude = JSONValue.double(from: coordinates[0]),
                  let latitude = JSONValue.double(from: coordinates[1]) else { return nil }
            return TMBPlaceBusStop(
                code: code,
                name: name,
                position: GeoPoint(latitude: latitude, longitude: longitude)
            )
        }
    }

    /// Every bus stop once, with the commercial names of the lines that serve
    /// it (spec S2).
    ///
    /// The network feed supplies names and coordinates; the per-line feeds
    /// supply the line membership. A stop present only in a per-line feed is
    /// kept, so a stale network snapshot never hides a stop the map draws.
    static func busPlaces(stops: [TMBPlaceBusStop], lines: [TMBPlaceBusLineStops]) -> [Place] {
        struct Group {
            let name: String
            let position: GeoPoint
            var lineCodes: Set<String>
        }

        var groups: [Int: Group] = [:]
        for stop in stops {
            groups[stop.code] = Group(name: stop.name, position: stop.position, lineCodes: [])
        }
        for line in lines {
            for stop in line.stops {
                let position = GeoPoint(latitude: stop.latitude, longitude: stop.longitude)
                if var group = groups[stop.code] {
                    group.lineCodes.insert(line.name)
                    groups[stop.code] = group
                } else {
                    groups[stop.code] = Group(name: stop.name, position: position, lineCodes: [line.name])
                }
            }
        }

        return groups.map { code, group in
            Place(
                kind: .busStop,
                code: String(code),
                name: group.name,
                position: group.position,
                lineCodes: group.lineCodes.sorted(),
                accessible: nil
            )
        }
        .sorted(by: placeOrder)
    }

    // MARK: - FGC

    /// FGC stations as places, with the routes whose published shape passes
    /// through the station (spec S2).
    ///
    /// `codigo-estaciones` carries the network line (1 = Barcelona-Vallès,
    /// 2 = Llobregat-Anoia), not the route code the FGC screens show, so the
    /// route is derived from geometry. Stations without a joined point are
    /// dropped: a place without a position cannot be drawn or measured.
    static func fgcPlaces(stations: [FGCStation], lines: [FGCLine]) -> [Place] {
        let geometries: [(code: String, polylines: [[GeoPoint]])] = lines.map { ($0.code, $0.polylines) }

        return stations.compactMap { station -> Place? in
            guard let point = station.point else { return nil }
            let lineCodes = fgcLineCodes(for: point, lines: geometries)
            return Place(
                kind: .fgcStation,
                code: station.code,
                name: station.name,
                position: point,
                lineCodes: lineCodes,
                accessible: nil
            )
        }
        .sorted(by: placeOrder)
    }

    /// Codes of the lines whose nearest polyline is within
    /// `fgcLineMatchMeters` of the station.
    static func fgcLineCodes(
        for point: GeoPoint,
        lines: [(code: String, polylines: [[GeoPoint]])]
    ) -> [String] {
        // One degree of latitude is ~111 km; a cheap bounding-box prefilter
        // keeps the per-station projection off the hundreds of long shapes that
        // cannot possibly be near it.
        let latitudeMargin = fgcLineMatchMeters / 111_000
        let longitudeMargin = latitudeMargin / max(0.01, cos(point.latitude * .pi / 180))

        var codes: [String] = []
        for line in lines {
            let touches = line.polylines.contains { polyline in
                guard let box = bounds(of: polyline) else { return false }
                guard point.latitude >= box.minLatitude - latitudeMargin,
                      point.latitude <= box.maxLatitude + latitudeMargin,
                      point.longitude >= box.minLongitude - longitudeMargin,
                      point.longitude <= box.maxLongitude + longitudeMargin else { return false }
                guard let projection = GeoMath.nearestProjection(of: point, in: polyline) else { return false }
                return projection.offsetMeters <= fgcLineMatchMeters
            }
            if touches, !codes.contains(line.code) {
                codes.append(line.code)
            }
        }
        return codes.sorted()
    }

    private static func bounds(
        of polyline: [GeoPoint]
    ) -> (minLatitude: Double, maxLatitude: Double, minLongitude: Double, maxLongitude: Double)? {
        guard let first = polyline.first else { return nil }
        var minLatitude = first.latitude
        var maxLatitude = first.latitude
        var minLongitude = first.longitude
        var maxLongitude = first.longitude
        for point in polyline.dropFirst() {
            minLatitude = min(minLatitude, point.latitude)
            maxLatitude = max(maxLatitude, point.latitude)
            minLongitude = min(minLongitude, point.longitude)
            maxLongitude = max(maxLongitude, point.longitude)
        }
        return (minLatitude, maxLatitude, minLongitude, maxLongitude)
    }

    // MARK: - Ordering

    /// Alphabetical by folded name, then by id: deterministic for tests and
    /// stable across launches.
    private static func placeOrder(_ lhs: Place, _ rhs: Place) -> Bool {
        let left = PlaceIndex.normalized(lhs.name)
        let right = PlaceIndex.normalized(rhs.name)
        if left != right { return left < right }
        return lhs.id < rhs.id
    }
}
