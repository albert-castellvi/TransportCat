import Foundation

/// Parsers for the bus endpoints of the TMB API. Every payload is GeoJSON or
/// plain JSON decoded with `JSONSerialization`, like the metro parsers, so the
/// app keeps a single (tolerant) decode path.
enum BusParser {
    enum ParseError: Error {
        case missingFeatures
    }

    /// Decodes the bus line catalog (`/transit/linies/bus`) into lines sorted by
    /// family order and then by line order inside the family, which is the
    /// order the picker shows them in.
    static func lines(from data: Data) throws -> [BusLine] {
        let features = try self.features(from: data)
        let lines = features.compactMap { feature -> BusLine? in
            guard let properties = JSONValue.dictionary(from: feature["properties"]),
                  let code = JSONValue.int(from: properties["CODI_LINIA"]),
                  let name = JSONValue.string(from: properties["NOM_LINIA"]) else {
                return nil
            }
            return BusLine(
                code: code,
                name: name,
                description: JSONValue.string(from: properties["DESC_LINIA"]) ?? "",
                origin: JSONValue.string(from: properties["ORIGEN_LINIA"]) ?? "",
                destination: JSONValue.string(from: properties["DESTI_LINIA"]) ?? "",
                colorHex: JSONValue.string(from: properties["COLOR_LINIA"]) ?? "",
                textColorHex: JSONValue.string(from: properties["COLOR_TEXT_LINIA"]) ?? "FFFFFF",
                familyCode: JSONValue.int(from: properties["CODI_FAMILIA"]) ?? 0,
                familyName: JSONValue.string(from: properties["NOM_FAMILIA"]) ?? "",
                familyOrder: JSONValue.int(from: properties["ORDRE_FAMILIA"]) ?? Int.max,
                order: JSONValue.int(from: properties["ORDRE_LINIA"]) ?? Int.max
            )
        }
        return lines.sorted { lhs, rhs in
            if lhs.familyOrder != rhs.familyOrder { return lhs.familyOrder < rhs.familyOrder }
            if lhs.order != rhs.order { return lhs.order < rhs.order }
            return lhs.code < rhs.code
        }
    }

    /// Decodes the stops of one line (`/transit/linies/bus/{code}/parades`).
    /// The response mixes both directions in one list, so the API order is kept
    /// and each stop carries its own `directionID` and `order`; callers group
    /// by direction and sort by `order` when they need a direction's sequence.
    static func stops(from data: Data) throws -> [BusStop] {
        let features = try self.features(from: data)
        return features.compactMap { feature -> BusStop? in
            guard let properties = JSONValue.dictionary(from: feature["properties"]),
                  let code = JSONValue.int(from: properties["CODI_PARADA"]),
                  let name = JSONValue.string(from: properties["NOM_PARADA"]) else {
                return nil
            }
            guard let geometry = JSONValue.dictionary(from: feature["geometry"]),
                  let coordinates = JSONValue.array(from: geometry["coordinates"]),
                  coordinates.count >= 2,
                  let longitude = JSONValue.double(from: coordinates[0]),
                  let latitude = JSONValue.double(from: coordinates[1]) else {
                return nil
            }
            return BusStop(
                code: code,
                name: name,
                address: JSONValue.string(from: properties["ADRECA"]) ?? "",
                order: JSONValue.int(from: properties["ORDRE"]) ?? Int.max,
                directionID: JSONValue.int(from: properties["ID_SENTIT"]) ?? 1,
                directionName: JSONValue.string(from: properties["DESC_SENTIT"]) ?? "",
                destinationName: JSONValue.string(from: properties["DESTI_SENTIT"]) ?? "",
                distanceFromPrevious: JSONValue.double(from: properties["DISTANCIA_PAR_ANTERIOR"]) ?? 0,
                latitude: latitude,
                longitude: longitude,
                routeID: JSONValue.int(from: properties["ID_RECORREGUT"]) ?? 0
            )
        }
    }

    /// Decodes the route geometries of one line (`/transit/linies/bus/{code}/recs`).
    /// The endpoint returns several variants per direction (day type, works);
    /// each feature becomes one `BusRoute`, and the caller picks the one whose
    /// `routeID` matches its stops' `ID_RECORREGUT`. Features without a usable
    /// polyline are dropped, since a route that cannot be drawn is no route.
    static func routes(from data: Data) throws -> [BusRoute] {
        let features = try self.features(from: data)
        return features.compactMap { feature -> BusRoute? in
            guard let properties = JSONValue.dictionary(from: feature["properties"]),
                  let routeID = JSONValue.int(from: properties["ID_RECORREGUT"]),
                  let directionID = JSONValue.int(from: properties["ID_SENTIT"]) else {
                return nil
            }
            guard let geometry = JSONValue.dictionary(from: feature["geometry"]),
                  let lineGeometry = self.geometry(from: geometry) else {
                return nil
            }
            return BusRoute(routeID: routeID, directionID: directionID, geometry: lineGeometry)
        }
    }

    /// Decodes the real-time bus arrivals of one stop
    /// (`/itransit/bus/parades/{code}`). The response lists every line serving
    /// the stop, so no line filter is applied: the stop sheet wants them all.
    /// Countdowns are derived from the response `timestamp` (the query time),
    /// which keeps the parse independent from the device clock, and overdue
    /// buses clamp to 0 instead of going negative.
    static func arrivals(from data: Data, stopCode: Int) throws -> [BusArrival] {
        let root = try JSONSerialization.jsonObject(with: data)
        guard let dict = JSONValue.dictionary(from: root),
              let parades = JSONValue.array(from: dict["parades"]) else {
            throw TMBError.unexpectedPayload("missing parades")
        }
        let referenceMillis = JSONValue.int(from: dict["timestamp"])
            ?? Int(Date().timeIntervalSince1970 * 1000)
        var result: [BusArrival] = []
        for parade in parades {
            guard let paradeDict = JSONValue.dictionary(from: parade) else { continue }
            // The stop code is repeated inside every parade; the requested code
            // is the fallback because older payloads omit it.
            let paradeStopCode = JSONValue.int(from: paradeDict["codi_parada"]) ?? stopCode
            for trajecte in JSONValue.array(from: paradeDict["linies_trajectes"]) ?? [] {
                guard let trajecteDict = JSONValue.dictionary(from: trajecte),
                      let lineCode = JSONValue.int(from: trajecteDict["codi_linia"]),
                      let destination = JSONValue.string(from: trajecteDict["desti_trajecte"]) else {
                    continue
                }
                let lineName = JSONValue.string(from: trajecteDict["nom_linia"]) ?? String(lineCode)
                let directionID = JSONValue.int(from: trajecteDict["id_sentit"]) ?? 1
                let trajectCode = JSONValue.string(from: trajecteDict["codi_trajecte"]) ?? ""
                for bus in JSONValue.array(from: trajecteDict["propers_busos"]) ?? [] {
                    guard let busDict = JSONValue.dictionary(from: bus),
                          let arrivalMillis = JSONValue.int(from: busDict["temps_arribada"]) else {
                        continue
                    }
                    let seconds = max(0, (arrivalMillis - referenceMillis) / 1000)
                    let accessibility = JSONValue.dictionary(from: busDict["info_bus"])
                        .flatMap { JSONValue.dictionary(from: $0["accessibilitat"]) }
                    result.append(BusArrival(
                        stopCode: paradeStopCode,
                        lineCode: lineCode,
                        lineName: lineName,
                        directionID: directionID,
                        trajectCode: trajectCode,
                        destination: destination,
                        seconds: seconds,
                        busID: JSONValue.int(from: busDict["id_bus"]),
                        rampStatus: JSONValue.string(from: accessibility?["estat_rampa"])
                    ))
                }
            }
        }
        return result
    }

    // MARK: - Shared helpers

    private static func features(from data: Data) throws -> [[String: Any]] {
        let root = try JSONSerialization.jsonObject(with: data)
        guard let dict = JSONValue.dictionary(from: root),
              let features = JSONValue.array(from: dict["features"]) else {
            throw ParseError.missingFeatures
        }
        return features.compactMap { JSONValue.dictionary(from: $0) }
    }

    /// Flattens one feature geometry into an ordered polyline. Bus routes come
    /// as MultiLineString segments (one per day type variant), which are
    /// concatenated in document order, the same way `GeoJSONParser.geometry`
    /// treats a metro line.
    private static func geometry(from geometry: [String: Any]) -> LineGeometry? {
        var points: [GeoPoint] = []
        switch geometry["type"] as? String {
        case "LineString":
            append(points: &points, fromCoordinates: geometry["coordinates"])
        case "MultiLineString":
            for segment in JSONValue.array(from: geometry["coordinates"]) ?? [] {
                append(points: &points, fromCoordinates: segment)
            }
        default:
            return nil
        }
        return points.isEmpty ? nil : LineGeometry(points: points)
    }

    private static func append(points: inout [GeoPoint], fromCoordinates any: Any?) {
        for coordinate in JSONValue.array(from: any) ?? [] {
            guard let pair = JSONValue.array(from: coordinate), pair.count >= 2,
                  let longitude = JSONValue.double(from: pair[0]),
                  let latitude = JSONValue.double(from: pair[1]) else {
                continue
            }
            points.append(GeoPoint(latitude: latitude, longitude: longitude))
        }
    }
}

/// Parser for the bus alerts feed (`/alerts/bus/channels/WEB`).
///
/// Bus alerts share the outer shape of the metro feed (`data.alerts[]`) but
/// carry a different payload: the disruption kind is `typeName` (free text, no
/// effect code), the affected stops live under
/// `linesAffected[].ways[].stops[]`, and the copy lives in `channelInfoTO`.
enum BusAlertParser {
    static func alerts(from data: Data) throws -> [ServiceAlert] {
        let root = try JSONSerialization.jsonObject(with: data)
        guard let dict = JSONValue.dictionary(from: root),
              let dataDict = JSONValue.dictionary(from: dict["data"]),
              let alerts = JSONValue.array(from: dataDict["alerts"]) else {
            throw TMBError.unexpectedPayload("missing data.alerts")
        }
        return alerts.compactMap { item -> ServiceAlert? in
            guard let alertDict = JSONValue.dictionary(from: item) else { return nil }
            var lineCodes: [String] = []
            var stationNames: [String] = []
            var stationCodes: [Int] = []
            for affected in JSONValue.array(from: alertDict["linesAffected"]) ?? [] {
                guard let affectedDict = JSONValue.dictionary(from: affected) else { continue }
                // `lineId` is the numeric code the catalog uses ("212"); the
                // commercial id ("H12") is only for display.
                if let lineCode = JSONValue.string(from: affectedDict["lineId"]),
                   !lineCodes.contains(lineCode) {
                    lineCodes.append(lineCode)
                }
                for way in JSONValue.array(from: affectedDict["ways"]) ?? [] {
                    guard let wayDict = JSONValue.dictionary(from: way) else { continue }
                    for stop in JSONValue.array(from: wayDict["stops"]) ?? [] {
                        guard let stopDict = JSONValue.dictionary(from: stop) else { continue }
                        if let code = JSONValue.int(from: stopDict["stopId"]), !stationCodes.contains(code) {
                            stationCodes.append(code)
                        }
                        if let name = JSONValue.string(from: stopDict["stopName"]), !stationNames.contains(name) {
                            stationNames.append(name)
                        }
                    }
                }
            }
            // `stopsAffected` is empty on every current alert but is the other
            // place the feed lists stops; accept both its shapes (objects and
            // bare codes) so a real payload is not lost.
            for stop in JSONValue.array(from: alertDict["stopsAffected"]) ?? [] {
                if let stopDict = JSONValue.dictionary(from: stop) {
                    if let code = JSONValue.int(from: stopDict["stopId"]), !stationCodes.contains(code) {
                        stationCodes.append(code)
                    }
                    if let name = JSONValue.string(from: stopDict["stopName"]), !stationNames.contains(name) {
                        stationNames.append(name)
                    }
                } else if let code = JSONValue.int(from: stop), !stationCodes.contains(code) {
                    stationCodes.append(code)
                }
            }
            var beginDate: Date?
            var endDate: Date?
            if let begin = alertDict["begin"] { beginDate = JSONValue.dateMilliseconds(from: begin) }
            if let end = alertDict["end"] { endDate = JSONValue.dateMilliseconds(from: end) }
            let channelInfo = JSONValue.dictionary(from: alertDict["channelInfoTO"])
            let text = JSONValue.string(from: channelInfo?["textCa"])
            let categories = JSONValue.dictionary(from: alertDict["categories"])
            let id = JSONValue.string(from: alertDict["id"])
                ?? JSONValue.string(from: alertDict["code"])
                ?? "\(lineCodes)-\(stationNames)-\(beginDate?.timeIntervalSince1970 ?? 0)"
            return ServiceAlert(
                id: id,
                lineCodes: lineCodes,
                stationNames: stationNames,
                beginDate: beginDate,
                endDate: endDate,
                text: text,
                stationCodes: stationCodes,
                entranceNames: [],
                effectCode: nil,
                effectType: JSONValue.string(from: categories?["messageType"]),
                typeName: JSONValue.string(from: alertDict["typeName"])
            )
        }
    }
}
