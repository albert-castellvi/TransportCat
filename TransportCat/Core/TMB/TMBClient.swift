import Foundation

/// Client for the public TMB API (https://api.tmb.cat/v1).
///
/// All requests append `app_id` and `app_key` query parameters. Parsing is
/// deliberately tolerant: TMB property shapes differ between line families
/// (L1–L5/L11 are rich, L9/L10/FM are minimal) and iBus mixes numeric and
/// textual countdowns, so unknown/missing fields never fail the decode.
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
    /// GET /transit/linies/metro/{code}/tram (GeoJSON LineString/MultiLineString)
    func lineGeometry(lineCode: String) async throws -> LineGeometry {
        let data = try await get(path: "transit/linies/metro/\(lineCode)/tram")
        return try GeoJSONParser.geometry(from: data)
    }

    /// Live arrivals at one stop of one line.
    /// GET /ibus/lines/{lineCode}/stops/{stopCode}
    func arrivals(lineCode: String, stopCode: Int) async throws -> [Arrival] {
        let data = try await get(path: "ibus/lines/\(lineCode)/stops/\(stopCode)")
        return try IBusParser.arrivals(from: data, lineCode: lineCode, stationCode: stopCode)
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
        components.queryItems = [
            URLQueryItem(name: "app_id", value: credentials.appId),
            URLQueryItem(name: "app_key", value: credentials.appKey),
        ]
        guard let url = components.url else { throw TMBError.invalidURL }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else {
            throw TMBError.unexpectedPayload("no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw TMBError.httpStatus(http.statusCode)
        }
        return data
    }

    static let baseURL = "https://api.tmb.cat/v1"
}
