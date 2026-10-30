import Foundation

/// Parsers for the GeoJSON responses of the TMB transit service.
enum GeoJSONParser {
    enum ParseError: Error {
        case missingFeatures
    }

    /// Decodes `features[]` of a stations FeatureCollection. Property names
    /// follow TMB's WFS export: NOM_ESTACIO, CODI_ESTACIO, ORDRE_ESTACIO,
    /// ID_ESTACIO, NOM_TIPUS_ACCESSIBILITAT... All 11 lines return the same 25
    /// properties, so `ID_ESTACIO` and `NOM_TIPUS_ACCESSIBILITAT` stay optional
    /// only because the schema does not guarantee them, not because some line
    /// family drops them.
    static func stations(from data: Data, lineCode: String) throws -> [Station] {
        let root = try JSONSerialization.jsonObject(with: data)
        guard let dict = JSONValue.dictionary(from: root),
              let features = JSONValue.array(from: dict["features"]) else {
            throw ParseError.missingFeatures
        }
        let stations = features.compactMap { feature -> Station? in
            guard let dict = JSONValue.dictionary(from: feature),
                  let properties = JSONValue.dictionary(from: dict["properties"]),
                  let name = JSONValue.string(from: properties["NOM_ESTACIO"]),
                  let code = JSONValue.int(from: properties["CODI_ESTACIO"]) else {
                return nil
            }
            guard let geometry = JSONValue.dictionary(from: dict["geometry"]),
                  let coordinates = JSONValue.array(from: geometry["coordinates"]),
                  coordinates.count >= 2,
                  let longitude = JSONValue.double(from: coordinates[0]),
                  let latitude = JSONValue.double(from: coordinates[1]) else {
                return nil
            }
            let order = JSONValue.int(from: properties["ORDRE_ESTACIO"]) ?? Int.max
            let accessibility = JSONValue.string(from: properties["NOM_TIPUS_ACCESSIBILITAT"])
            return Station(
                code: code,
                name: name,
                orderInLine: order,
                lineCode: lineCode,
                latitude: latitude,
                longitude: longitude,
                id: JSONValue.int(from: properties["ID_ESTACIO"]),
                accessible: accessibility.map { $0.caseInsensitiveCompare("Accessible") == .orderedSame }
            )
        }
        return stations.sorted { $0.orderInLine < $1.orderInLine }
    }

    /// Decodes a line geometry into an ordered polyline. Accepts LineString
    /// ([lng,lat]...) and MultiLineString ([[lng,lat]...]-...), bare or wrapped
    /// in a FeatureCollection; for MultiLineString the segments are
    /// concatenated in document order, which matches how TMB exports
    /// continuous routes.
    static func geometry(from data: Data) throws -> LineGeometry {
        let root = try JSONSerialization.jsonObject(with: data)
        guard let dict = JSONValue.dictionary(from: root) else {
            throw ParseError.missingFeatures
        }
        var points: [GeoPoint] = []
        switch dict["type"] as? String {
        case "LineString":
            append(points: &points, fromCoordinates: dict["coordinates"])
        case "MultiLineString":
            for segment in JSONValue.array(from: dict["coordinates"]) ?? [] {
                append(points: &points, fromCoordinates: segment)
            }
        case "FeatureCollection":
            for feature in JSONValue.array(from: dict["features"]) ?? [] {
                guard let featureDict = JSONValue.dictionary(from: feature),
                      let geometryDict = JSONValue.dictionary(from: featureDict["geometry"]) else {
                    continue
                }
                if geometryDict["type"] as? String == "LineString" {
                    append(points: &points, fromCoordinates: geometryDict["coordinates"])
                } else if geometryDict["type"] as? String == "MultiLineString" {
                    for segment in JSONValue.array(from: geometryDict["coordinates"]) ?? [] {
                        append(points: &points, fromCoordinates: segment)
                    }
                }
            }
        default:
            throw ParseError.missingFeatures
        }
        guard !points.isEmpty else { throw ParseError.missingFeatures }
        return LineGeometry(points: points)
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

/// Parser for the i-Metro arrivals response:
/// `{"timestamp":...,"linies":[{"codi_linia":1,"nom_linia":"L1",
/// "estacions":[{"codi_estacio":111,"linies_trajectes":[{"desti_trajecte":
/// "Fondo","propers_trens":[{"codi_servei":"120",
/// "temps_arribada":1746450647000}]}]}]}]}` (docs/tmb-api/imetro.swagger.json).
enum MetroParser {
    /// Arrivals grouped by station code. The response lists every line that
    /// serves the queried stations, so only the requested line is kept;
    /// countdowns are derived from the response `timestamp` (the query time),
    /// which keeps the parse independent from the device clock.
    static func arrivals(from data: Data, lineCode: String) throws -> [Int: [Arrival]] {
        let root = try JSONSerialization.jsonObject(with: data)
        guard let dict = JSONValue.dictionary(from: root),
              let lines = JSONValue.array(from: dict["linies"]) else {
            throw TMBError.unexpectedPayload("missing linies")
        }
        let referenceMillis = JSONValue.int(from: dict["timestamp"])
            ?? Int(Date().timeIntervalSince1970 * 1000)
        var result: [Int: [Arrival]] = [:]
        for line in lines {
            guard let lineDict = JSONValue.dictionary(from: line),
                  isRequestedLine(lineCode: lineCode, line: lineDict) else {
                continue
            }
            for station in JSONValue.array(from: lineDict["estacions"]) ?? [] {
                guard let stationDict = JSONValue.dictionary(from: station),
                      let stationCode = JSONValue.int(from: stationDict["codi_estacio"]) else {
                    continue
                }
                // One entry per via/sentit: the direction (1 = toward the
                // last station, 2 = toward the first) lives on the station
                // entry, not on each train.
                let via = JSONValue.int(from: stationDict["codi_via"])
                var stationArrivals: [Arrival] = []
                // A station repeats once per via/sentit, so its arrivals must
                // be appended, never overwritten.
                for trajecte in JSONValue.array(from: stationDict["linies_trajectes"]) ?? [] {
                    guard let trajecteDict = JSONValue.dictionary(from: trajecte),
                          let destination = JSONValue.string(from: trajecteDict["desti_trajecte"]) else {
                        continue
                    }
                    // `codi_trajecte` ("0011", "0012") identifies the route
                    // variant; the engine pairs it with `codi_servei` to tell
                    // one physical train from another (S1).
                    let trajectCode = JSONValue.string(from: trajecteDict["codi_trajecte"])
                    for train in JSONValue.array(from: trajecteDict["propers_trens"]) ?? [] {
                        guard let trainDict = JSONValue.dictionary(from: train),
                              let arrivalMillis = JSONValue.int(from: trainDict["temps_arribada"]) else {
                            continue
                        }
                        // Overdue trains (arrival before the query time)
                        // clamp to 0 instead of going negative.
                        let seconds = max(0, (arrivalMillis - referenceMillis) / 1000)
                        stationArrivals.append(Arrival(
                            stationCode: stationCode,
                            lineCode: lineCode,
                            destination: destination,
                            seconds: seconds,
                            rawText: Arrival.countdownText(seconds: seconds),
                            serviceCode: JSONValue.string(from: trainDict["codi_servei"]),
                            trajectCode: trajectCode,
                            via: via
                        ))
                    }
                }
                if !stationArrivals.isEmpty {
                    result[stationCode, default: []].append(contentsOf: stationArrivals)
                }
            }
        }
        return result
    }

    /// `codi_linia` is an integer (94 for L9N) and app line codes are its string
    /// form; `nom_linia` ("L1", "L9N", "FM") is matched as a fallback.
    private static func isRequestedLine(lineCode: String, line: [String: Any]) -> Bool {
        if let coded = JSONValue.int(from: line["codi_linia"]), String(coded) == lineCode {
            return true
        }
        guard let name = JSONValue.string(from: line["nom_linia"])?.uppercased() else { return false }
        let requested = lineCode.uppercased()
        return name == requested || name == "L" + requested
    }
}

/// Parser for the alerts response: `{"data":{"alerts":[...]}}`.
enum AlertParser {
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
            var entranceNames: [String] = []
            for entity in JSONValue.array(from: alertDict["entities"]) ?? [] {
                guard let entityDict = JSONValue.dictionary(from: entity) else { continue }
                if let lineCode = JSONValue.string(from: entityDict["line_code"]), !lineCodes.contains(lineCode) {
                    lineCodes.append(lineCode)
                }
                if let stationName = JSONValue.string(from: entityDict["station_name"]), !stationNames.contains(stationName) {
                    stationNames.append(stationName)
                }
                // `station_code` is a numeric string ("136"); a line-wide
                // alert sends ALL, which is not a station code.
                if let code = stationCode(from: entityDict["station_code"]),
                   !stationCodes.contains(code) {
                    stationCodes.append(code)
                }
                // `entrance_name` is absent on some entities, and ALL when the
                // whole station is affected.
                if let entranceName = JSONValue.string(from: entityDict["entrance_name"]),
                   entranceName.caseInsensitiveCompare("ALL") != .orderedSame,
                   !entranceNames.contains(entranceName) {
                    entranceNames.append(entranceName)
                }
            }
            // `effect_code` tells the kind of disruption: PP2 corridors
            // closed, PP7 access closed, PP8 elevator out, PP9 escalator out.
            let categories = JSONValue.dictionary(from: alertDict["categories"])
            let effectCode = JSONValue.string(from: categories?["effect_code"])
            var beginDate: Date?
            var endDate: Date?
            if let dates = JSONValue.array(from: alertDict["disruption_dates"]),
               let first = JSONValue.dictionary(from: dates.first) {
                beginDate = JSONValue.dateMilliseconds(from: first["begin_date"])
                endDate = JSONValue.dateMilliseconds(from: first["end_date"])
            }
            let text = publicationText(from: alertDict)
                ?? JSONValue.string(from: alertDict["description"])
                ?? JSONValue.string(from: alertDict["text_ca"])
                ?? JSONValue.string(from: alertDict["text"])
            let id = JSONValue.string(from: alertDict["id"])
                ?? JSONValue.string(from: alertDict["alert_id"])
                ?? "\(lineCodes)-\(stationNames)-\(beginDate?.timeIntervalSince1970 ?? 0)"
            return ServiceAlert(
                id: id,
                lineCodes: lineCodes,
                stationNames: stationNames,
                beginDate: beginDate,
                endDate: endDate,
                text: text,
                stationCodes: stationCodes,
                entranceNames: entranceNames,
                effectCode: effectCode
            )
        }
    }

    /// `station_code` arrives as a string ("136") and must stay numeric: ALL
    /// and any other non-numeric value mean no particular station.
    private static func stationCode(from any: Any?) -> Int? {
        if let string = any as? String {
            return Int(string.trimmingCharacters(in: .whitespaces))
        }
        return JSONValue.int(from: any)
    }

    /// Live alerts carry no top-level text: the disruption copy lives in
    /// `publications[]`, as `textCa` (Catalan), `textEs` or `textEn`. The first
    /// publication with text wins, preferring Catalan within it. The legacy
    /// top-level keys stay as a last resort for older payloads.
    private static func publicationText(from alert: [String: Any]) -> String? {
        for publication in JSONValue.array(from: alert["publications"]) ?? [] {
            guard let dict = JSONValue.dictionary(from: publication) else { continue }
            for key in ["textCa", "textEs", "textEn"] {
                if let text = JSONValue.string(from: dict[key]), !text.isEmpty {
                    return text
                }
            }
        }
        return nil
    }
}
