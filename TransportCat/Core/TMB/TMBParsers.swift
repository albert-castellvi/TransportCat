import Foundation

/// Parsers for the GeoJSON responses of the TMB transit service.
enum GeoJSONParser {
    enum ParseError: Error {
        case missingFeatures
    }

    /// Decodes `features[]` of a stations FeatureCollection. Property names
    /// follow TMB's WFS export: NOM_ESTACIO, CODI_ESTACIO, ORDRE_ESTACIO,
    /// ID_ESTACIO, NOM_TIPUS_ACCESSIBILITAT... Features of L9/L10/FM carry
    /// only the minimal set; every extra field is optional.
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

    /// Decodes a tram geometry into an ordered polyline. Accepts LineString
    /// ([lng,lat]...) and MultiLineString ([[lng,lat]...]-...); for
    /// MultiLineString the segments are concatenated in document order, which
    /// matches how TMB exports continuous routes.
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

/// Parser for the iBus arrivals response:
/// `{"data":{"ibus":[{"min":...,"text_ca":...,"dest":...}]}}`.
enum IBusParser {
    static func arrivals(from data: Data, lineCode: String, stationCode: Int) throws -> [Arrival] {
        let root = try JSONSerialization.jsonObject(with: data)
        guard let dict = JSONValue.dictionary(from: root),
              let dataDict = JSONValue.dictionary(from: dict["data"]),
              let ibus = JSONValue.array(from: dataDict["ibus"]) else {
            throw TMBError.unexpectedPayload("missing data.ibus")
        }
        return ibus.compactMap { item -> Arrival? in
            guard let itemDict = JSONValue.dictionary(from: item) else { return nil }
            let destination = JSONValue.string(from: itemDict["dest"])
                ?? JSONValue.string(from: itemDict["destination"])
                ?? ""
            let rawText = JSONValue.string(from: itemDict["text_ca"])
                ?? JSONValue.string(from: itemDict["text"])
                ?? JSONValue.string(from: itemDict["min"])
                ?? ""
            return Arrival(
                stationCode: stationCode,
                lineCode: lineCode,
                destination: destination,
                seconds: JSONValue.int(from: itemDict["min"]).map { $0 * 60 },
                rawText: rawText
            )
        }
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
            for entity in JSONValue.array(from: alertDict["entities"]) ?? [] {
                guard let entityDict = JSONValue.dictionary(from: entity) else { continue }
                if let lineCode = JSONValue.string(from: entityDict["line_code"]), !lineCodes.contains(lineCode) {
                    lineCodes.append(lineCode)
                }
                if let stationName = JSONValue.string(from: entityDict["station_name"]), !stationNames.contains(stationName) {
                    stationNames.append(stationName)
                }
            }
            var beginDate: Date?
            var endDate: Date?
            if let dates = JSONValue.array(from: alertDict["disruption_dates"]),
               let first = JSONValue.dictionary(from: dates.first) {
                beginDate = JSONValue.dateMilliseconds(from: first["begin_date"])
                endDate = JSONValue.dateMilliseconds(from: first["end_date"])
            }
            let text = JSONValue.string(from: alertDict["description"])
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
                text: text
            )
        }
    }
}
