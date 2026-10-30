import Foundation

/// Client for the public TMB API (https://api.tmb.cat/v1).
///
/// All requests append `app_id` and `app_key` query parameters. Parsing is
/// deliberately tolerant: optional fields the schema allows to be absent never
/// fail the decode (in practice all 11 lines return the same station
/// properties), and i-Metro reports absolute timestamps instead of countdowns,
/// which the parser converts against the response time.
final class TMBClient {
    private let session: URLSession
    private let credentials: TMBCredentials

    init(session: URLSession = .shared, credentials: TMBCredentials) {
        self.session = session
        self.credentials = credentials
    }

    /// Convenience factory that reads credentials from the app's Info.plist.
    static func fromBundle(session: URLSession = .shared, infoDictionary: [String: Any]? = Bundle.main.infoDictionary) throws -> TMBClient {
        TMBClient(session: session, credentials: try TMBCredentials.fromBundle(infoDictionary))
    }

    // MARK: - Endpoints

    /// Stations of one line, ordered by `ORDRE_ESTACIO`.
    /// GET /transit/linies/metro/{code}/estacions (GeoJSON FeatureCollection)
    func stations(lineCode: String) async throws -> [Station] {
        let data = try await get(path: "transit/linies/metro/\(lineCode)/estacions")
        return try GeoJSONParser.stations(from: data, lineCode: lineCode)
    }

    /// Physical route of one line as an ordered polyline.
    /// GET /transit/linies/metro/{code} (GeoJSON FeatureCollection whose
    /// geometry is the line's MultiLineString)
    func lineGeometry(lineCode: String) async throws -> LineGeometry {
        let data = try await get(path: "transit/linies/metro/\(lineCode)")
        return try GeoJSONParser.geometry(from: data)
    }

    /// Live train arrivals for one or more stations of one line.
    /// GET /itransit/metro/estacions?estacions={comma-separated station codes}
    /// Returns arrivals grouped by station code; a station without trains in
    /// the response is simply absent from the result.
    func metroArrivals(lineCode: String, stationCodes: [Int]) async throws -> [Int: [Arrival]] {
        let codes = stationCodes.map(String.init).joined(separator: ",")
        let data = try await get(path: "itransit/metro/estacions?estacions=\(codes)")
        return try MetroParser.arrivals(from: data, lineCode: lineCode)
    }

    /// Current metro service alerts.
    /// GET /alerts/metro/channels/WEB
    func alerts() async throws -> [ServiceAlert] {
        let data = try await get(path: "alerts/metro/channels/WEB")
        return try AlertParser.alerts(from: data)
    }

    // MARK: - Transport

    private func get(path: String) async throws -> Data {
        guard var components = URLComponents(string: "\(Self.baseURL)/\(path)") else {
            throw TMBError.invalidURL
        }
        // Some paths carry their own query (i-Metro `estacions`), so keep the
        // existing items and append the credentials after them.
        var queryItems = components.queryItems ?? []
        queryItems.append(URLQueryItem(name: "app_id", value: credentials.appId))
        queryItems.append(URLQueryItem(name: "app_key", value: credentials.appKey))
        components.queryItems = queryItems
        guard let url = components.url else { throw TMBError.invalidURL }

        // The arrivals poll runs every 20 s; the 60 s URLSession default would
        // freeze the trains for several cycles behind one stalled request.
        let request = URLRequest(url: url, timeoutInterval: Self.requestTimeoutSeconds)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TMBError.unexpectedPayload("no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw TMBError.httpStatus(http.statusCode)
        }
        return data
    }

    static let baseURL = "https://api.tmb.cat/v1"
    static let requestTimeoutSeconds: TimeInterval = 10
}
