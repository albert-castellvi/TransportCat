import Foundation

/// Bus endpoints of the TMB API, kept out of `TMBClient` so the metro client
/// stays focused. They travel through the same credentialed `get(path:)`, so
/// bus requests share its timeout and error mapping.
extension TMBClient {
    /// Full bus line catalog, already sorted by family and line order.
    /// GET /transit/linies/bus (GeoJSON FeatureCollection)
    func busLines() async throws -> [BusLine] {
        let data = try await get(path: "transit/linies/bus")
        return try BusParser.lines(from: data)
    }

    /// Stops of one line, both directions in a single list.
    /// GET /transit/linies/bus/{code}/parades (GeoJSON FeatureCollection)
    func busStops(lineCode: Int) async throws -> [BusStop] {
        let data = try await get(path: "transit/linies/bus/\(lineCode)/parades")
        return try BusParser.stops(from: data)
    }

    /// Route geometries of one line, one feature per direction variant.
    /// GET /transit/linies/bus/{code}/recs (GeoJSON FeatureCollection)
    func busRoutes(lineCode: Int) async throws -> [BusRoute] {
        let data = try await get(path: "transit/linies/bus/\(lineCode)/recs")
        return try BusParser.routes(from: data)
    }

    /// Live bus arrivals of one stop, every line that serves it.
    /// GET /itransit/bus/parades/{stop}
    func busArrivals(stopCode: Int) async throws -> [BusArrival] {
        let data = try await get(path: "itransit/bus/parades/\(stopCode)")
        return try BusParser.arrivals(from: data, stopCode: stopCode)
    }

    /// Current bus service alerts.
    /// GET /alerts/bus/channels/WEB
    func busAlerts() async throws -> [ServiceAlert] {
        let data = try await get(path: "alerts/bus/channels/WEB")
        return try BusAlertParser.alerts(from: data)
    }
}
