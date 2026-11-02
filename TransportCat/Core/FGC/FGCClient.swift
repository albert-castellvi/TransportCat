import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Client for the FGC open-data portal (`dadesobertes.fgc.cat`, spec S1).
///
/// The portal needs no credentials. Every dataset is read through the v2.1
/// records endpoint; `limit` is capped at 100, so the stop and station
/// catalogs are paged with `offset` until a page is short. The request timeout
/// matches `TMBClient.requestTimeoutSeconds` because a stalled request must
/// not freeze the 30 s live-train poll for several cycles.
final class FGCClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Endpoints

    /// `gtfs_routes`: lines with colour and GeoJSON shape (spec S1).
    func routes() async throws -> [FGCLine] {
        let data = try await get(dataset: "gtfs_routes")
        return try FGCParser.routes(from: data)
    }

    /// `lineas-red-fgc`: `route_id -> route_text_color` (spec S1).
    func lineTextColors() async throws -> [String: String] {
        let data = try await get(dataset: "lineas-red-fgc")
        return try FGCParser.textColors(from: data)
    }

    /// `codigo-estaciones`, paged (spec S2).
    func stations() async throws -> [FGCStation] {
        try await allPages(dataset: "codigo-estaciones", parse: FGCParser.stations(fromRecords:))
    }

    /// `gtfs_stops`, paged (spec S2).
    func allStops() async throws -> [FGCStop] {
        try await allPages(dataset: "gtfs_stops", parse: FGCParser.stops(fromRecords:))
    }

    /// `posicionament-dels-trens`: the live trains (spec S3). `stationNames`
    /// resolves each `desti` code to a station name.
    func liveTrains(stationNames: [String: String] = [:]) async throws -> [FGCTrain] {
        let data = try await get(dataset: "posicionament-dels-trens")
        return try FGCParser.trains(from: data, stationNames: stationNames)
    }

    // MARK: - Transport

    /// Reads every page of a dataset: one request per 100 rows until a page
    /// comes back short (or empty), which is the end of the catalog.
    private func allPages<Row>(
        dataset: String,
        parse: ([[String: Any]]) -> [Row]
    ) async throws -> [Row] {
        var result: [Row] = []
        var offset = 0
        while true {
            let data = try await get(
                dataset: dataset,
                queryItems: [URLQueryItem(name: "offset", value: String(offset))]
            )
            let records = try FGCParser.records(from: data)
            result.append(contentsOf: parse(records))
            guard records.count >= Self.pageSize else { break }
            offset += Self.pageSize
        }
        return result
    }

    private func get(dataset: String, queryItems: [URLQueryItem] = []) async throws -> Data {
        guard var components = URLComponents(string: "\(Self.baseURL)/\(dataset)/records") else {
            throw FGCError.invalidURL
        }
        components.queryItems = [URLQueryItem(name: "limit", value: String(Self.pageSize))] + queryItems
        guard let url = components.url else { throw FGCError.invalidURL }

        let request = URLRequest(url: url, timeoutInterval: Self.requestTimeoutSeconds)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw FGCError.unexpectedPayload("no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw FGCError.httpStatus(http.statusCode)
        }
        return data
    }

    static let baseURL = "https://dadesobertes.fgc.cat/api/explore/v2.1/catalog/datasets"
    static let requestTimeoutSeconds: TimeInterval = 10
    /// Server-side maximum for `limit`.
    static let pageSize = 100
}
