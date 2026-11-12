import Foundation

/// Codable mirrors of the topology models for the offline cache (spec S21).
///
/// The domain types (`Station`, `BusLine`, `FGCLine`...) are decoded straight
/// from TMB and FGC payloads and do not carry `Codable`; adding it to them
/// would mean editing the model files of other tasks. These snapshots instead
/// live entirely in the cache layer: one field-by-field copy in and out, with
/// the geometry flattened to plain `GeoPoint` arrays, which are already
/// codable through `GeoPoint+Place.swift`.

// MARK: - Metro

struct StationSnapshot: Codable, Equatable {
    let code: Int
    let name: String
    let orderInLine: Int
    let lineCode: String
    let latitude: Double
    let longitude: Double
    let id: Int?
    let accessible: Bool?

    init(_ station: Station) {
        code = station.code
        name = station.name
        orderInLine = station.orderInLine
        lineCode = station.lineCode
        latitude = station.latitude
        longitude = station.longitude
        id = station.id
        accessible = station.accessible
    }

    var station: Station {
        Station(
            code: code,
            name: name,
            orderInLine: orderInLine,
            lineCode: lineCode,
            latitude: latitude,
            longitude: longitude,
            id: id,
            accessible: accessible
        )
    }
}

/// One metro line's topology: its stations in API order plus the route
/// polyline, nil when the app only ever had the coarse fallback line.
struct MetroTopologySnapshot: Codable, Equatable {
    let stations: [StationSnapshot]
    let geometryPoints: [GeoPoint]?

    init(stations: [Station], geometry: LineGeometry?) {
        self.stations = stations.map(StationSnapshot.init)
        geometryPoints = geometry?.points
    }

    func apply() -> (stations: [Station], geometry: LineGeometry?) {
        (stations.map { $0.station }, geometryPoints.map(LineGeometry.init(points:)))
    }
}

// MARK: - Bus

struct BusLineSnapshot: Codable, Equatable {
    let code: Int
    let name: String
    let description: String
    let origin: String
    let destination: String
    let colorHex: String
    let textColorHex: String
    let familyCode: Int
    let familyName: String
    let familyOrder: Int
    let order: Int

    init(_ line: BusLine) {
        code = line.code
        name = line.name
        description = line.description
        origin = line.origin
        destination = line.destination
        colorHex = line.colorHex
        textColorHex = line.textColorHex
        familyCode = line.familyCode
        familyName = line.familyName
        familyOrder = line.familyOrder
        order = line.order
    }

    var busLine: BusLine {
        BusLine(
            code: code,
            name: name,
            description: description,
            origin: origin,
            destination: destination,
            colorHex: colorHex,
            textColorHex: textColorHex,
            familyCode: familyCode,
            familyName: familyName,
            familyOrder: familyOrder,
            order: order
        )
    }
}

struct BusStopSnapshot: Codable, Equatable {
    let code: Int
    let name: String
    let address: String
    let order: Int
    let directionID: Int
    let directionName: String
    let destinationName: String
    let distanceFromPrevious: Double
    let latitude: Double
    let longitude: Double
    let routeID: Int

    init(_ stop: BusStop) {
        code = stop.code
        name = stop.name
        address = stop.address
        order = stop.order
        directionID = stop.directionID
        directionName = stop.directionName
        destinationName = stop.destinationName
        distanceFromPrevious = stop.distanceFromPrevious
        latitude = stop.latitude
        longitude = stop.longitude
        routeID = stop.routeID
    }

    var busStop: BusStop {
        BusStop(
            code: code,
            name: name,
            address: address,
            order: order,
            directionID: directionID,
            directionName: directionName,
            destinationName: destinationName,
            distanceFromPrevious: distanceFromPrevious,
            latitude: latitude,
            longitude: longitude,
            routeID: routeID
        )
    }
}

struct BusRouteSnapshot: Codable, Equatable {
    let routeID: Int
    let directionID: Int
    let points: [GeoPoint]

    init(_ route: BusRoute) {
        routeID = route.routeID
        directionID = route.directionID
        points = route.geometry.points
    }

    var busRoute: BusRoute {
        BusRoute(routeID: routeID, directionID: directionID, geometry: LineGeometry(points: points))
    }
}

/// One bus line's topology: every stop of both directions and the route
/// geometries, exactly what the two iBus requests returned. Directions are
/// rebuilt from them by `BusFleet.directions`, never cached.
struct BusTopologySnapshot: Codable, Equatable {
    let stops: [BusStopSnapshot]
    let routes: [BusRouteSnapshot]

    init(stops: [BusStop], routes: [BusRoute]) {
        self.stops = stops.map(BusStopSnapshot.init)
        self.routes = routes.map(BusRouteSnapshot.init)
    }

    func apply() -> (stops: [BusStop], routes: [BusRoute]) {
        (stops.map { $0.busStop }, routes.map { $0.busRoute })
    }
}

// MARK: - FGC

struct FGCLineSnapshot: Codable, Equatable {
    let code: String
    let name: String
    let colorHex: String
    let textColorHex: String
    let polylines: [[GeoPoint]]

    init(_ line: FGCLine) {
        code = line.code
        name = line.name
        colorHex = line.colorHex
        textColorHex = line.textColorHex
        polylines = line.polylines
    }

    var fgcLine: FGCLine {
        FGCLine(code: code, name: name, colorHex: colorHex, textColorHex: textColorHex, polylines: polylines)
    }
}

struct FGCStationSnapshot: Codable, Equatable {
    let code: String
    let name: String
    let networkLine: Int
    let order: Int
    let point: GeoPoint?
    /// Optional so snapshots written before the field existed still decode
    /// (#75); no cache version bump is needed.
    let wheelchairBoarding: Int?

    init(_ station: FGCStation) {
        code = station.code
        name = station.name
        networkLine = station.networkLine
        order = station.order
        point = station.point
        wheelchairBoarding = station.wheelchairBoarding
    }

    var fgcStation: FGCStation {
        FGCStation(
            code: code,
            name: name,
            networkLine: networkLine,
            order: order,
            point: point,
            wheelchairBoarding: wheelchairBoarding
        )
    }
}

/// The FGC network as `FGCNetworkState` publishes it after merging routes,
/// colours and joined station coordinates, so a cached copy needs none of the
/// three source requests back.
struct FGCTopologySnapshot: Codable, Equatable {
    let lines: [FGCLineSnapshot]
    let stations: [FGCStationSnapshot]

    init(lines: [FGCLine], stations: [FGCStation]) {
        self.lines = lines.map(FGCLineSnapshot.init)
        self.stations = stations.map(FGCStationSnapshot.init)
    }

    func apply() -> (lines: [FGCLine], stations: [FGCStation]) {
        (lines.map { $0.fgcLine }, stations.map { $0.fgcStation })
    }
}
