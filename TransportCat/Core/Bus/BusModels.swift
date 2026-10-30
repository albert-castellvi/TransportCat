import Foundation

/// A bus line from the TMB bus catalog (`/transit/linies/bus`).
///
/// The catalog is a GeoJSON FeatureCollection whose properties carry the whole
/// line: the numeric code (212), the commercial name ("H12"), the family it
/// belongs to and the order inside that family. Geometry is not decoded: the
/// map draws routes from `/recs`, which is per direction.
struct BusLine: Identifiable, Hashable {
    /// TMB `CODI_LINIA` (212 for H12).
    let code: Int
    /// Commercial name shown on the badge ("H12").
    let name: String
    /// `DESC_LINIA`: the line's headline.
    let description: String
    let origin: String
    let destination: String
    /// `COLOR_LINIA` as delivered ("003888", no leading `#`).
    let colorHex: String
    /// `COLOR_TEXT_LINIA`, the color that reads on `colorHex`.
    let textColorHex: String
    let familyCode: Int
    /// `NOM_FAMILIA` ("Horitzontals", "Verticals"...).
    let familyName: String
    /// `ORDRE_FAMILIA`: families are ordered by this, not alphabetically.
    let familyOrder: Int
    /// `ORDRE_LINIA`: position inside its family.
    let order: Int

    var id: Int { code }
}

/// One bus family (Horitzontals, Verticals...) with its lines.
struct BusFamily: Identifiable, Hashable {
    let code: Int
    let name: String
    /// `ORDRE_FAMILIA` of the family.
    let order: Int
    /// Member lines, already sorted by `BusLine.order`.
    let lines: [BusLine]

    var id: Int { code }
}

/// A bus stop of one direction of one line, decoded from
/// `/transit/linies/bus/{code}/parades`.
///
/// The endpoint returns both directions in a single list, so the direction is
/// part of the stop's identity: the same physical stop appears twice (once per
/// direction) with its own `order` and `routeID`.
struct BusStop: Identifiable, Hashable {
    /// `CODI_PARADA`: the stop code the real-time (iBus) feed expects.
    let code: Int
    let name: String
    let address: String
    /// `ORDRE`: position inside its own direction, not the whole list.
    let order: Int
    /// `ID_SENTIT`: 1 = Anada, 2 = Tornada.
    let directionID: Int
    /// `DESC_SENTIT`.
    let directionName: String
    /// `DESTI_SENTIT`: where this direction ends.
    let destinationName: String
    /// `DISTANCIA_PAR_ANTERIOR`: meters from the previous stop of the route.
    let distanceFromPrevious: Double
    let latitude: Double
    let longitude: Double
    /// `ID_RECORREGUT`: the route geometry this direction's stops belong to.
    let routeID: Int

    /// The same physical stop appears in both directions, so identity needs
    /// the direction too.
    var id: String { "\(directionID)-\(code)" }

    /// Projects the stop into the metro `Station` shape so the metro
    /// `TrainPositionEngine` and `IncidentIndex` can be reused unchanged.
    func asStation(lineCode: String) -> Station {
        Station(
            code: code,
            name: name,
            orderInLine: order,
            lineCode: lineCode,
            latitude: latitude,
            longitude: longitude,
            id: nil,
            accessible: nil
        )
    }
}

/// Route polyline of one direction, decoded from
/// `/transit/linies/bus/{code}/recs`.
///
/// The endpoint returns several variants (day type and direction); the one a
/// direction draws is the one whose `ID_RECORREGUT` matches its stops'.
struct BusRoute: Hashable {
    let routeID: Int
    let directionID: Int
    let geometry: LineGeometry

    // `LineGeometry` is `Equatable` but not `Hashable`, and it belongs to the
    // metro model, so the conformance is spelled out here: identity comes from
    // the route and direction, and the polyline is compared point by point.
    static func == (lhs: BusRoute, rhs: BusRoute) -> Bool {
        lhs.routeID == rhs.routeID
            && lhs.directionID == rhs.directionID
            && lhs.geometry == rhs.geometry
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(routeID)
        hasher.combine(directionID)
    }
}

/// One bus approaching one stop, decoded from the per-stop iBus feed
/// (`/itransit/bus/parades/{stop}`).
struct BusArrival: Identifiable, Hashable {
    /// `codi_parada`: the stop this arrival belongs to.
    let stopCode: Int
    /// `codi_linia` (numeric line code, 212 for H12).
    let lineCode: Int
    /// `nom_linia` ("H12", "V1"...).
    let lineName: String
    let directionID: Int
    /// `codi_trajecte`: route variant of this bus.
    let trajectCode: String
    /// `desti_trajecte`: the head sign.
    let destination: String
    /// Countdown in seconds from the response `timestamp`, clamped at 0.
    let seconds: Int
    /// `id_bus`; nil when the feed has no bus identity for the arrival, which
    /// means the arrival cannot be placed on the map.
    let busID: Int?
    /// `info_bus.accessibilitat.estat_rampa`, kept raw ("SENSE_INCIDENCIA"...).
    let rampStatus: String?

    /// Ramp state as a three-way value: nil when the feed says nothing, `true`
    /// when the ramp is working, `false` for any other known state (an
    /// incidence the sheet shows in orange).
    var rampOperational: Bool? {
        guard let rampStatus else { return nil }
        return rampStatus.caseInsensitiveCompare("SENSE_INCIDENCIA") == .orderedSame
    }

    var id: String {
        "\(stopCode)-\(lineCode)-\(busID.map(String.init) ?? "\(trajectCode)-\(seconds)")"
    }
}
