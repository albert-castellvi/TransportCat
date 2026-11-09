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
    /// Station feeds already fetched by the place-code bridge, per line. Metro
    /// topology is immutable in practice and the bridge runs on every arrivals
    /// pass, so the cache keeps the translation from doubling the request
    /// count of a poll. A relaunch starts it empty. Main-actor isolated: one
    /// client is shared by every screen, and their passes run concurrently.
    @MainActor private var stationFeedCache: [String: [Station]] = [:]

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

    /// Live arrivals of one metro line for the given places, keyed by
    /// `Place.id`.
    ///
    /// `Place.code` — and the station sheets reached from a place — carry the
    /// line-independent `ID_ESTACIO`, while i-Metro keys its answer by the
    /// per-line `CODI_ESTACIO`. Every code is therefore translated through the
    /// line's own station feed before the request (see
    /// `TMBPlaceParser.stationCode(forPlaceCode:name:in:)`) and the answer is
    /// mapped back to the place the caller asked for, so a caller never has to
    /// know which code space it holds. A failed station feed falls back to the
    /// codes as given.
    func metroArrivals(lineCode: String, places: [Place]) async throws -> [String: [Arrival]] {
        let feed = await stationFeed(lineCode: lineCode)
        let requested = places.compactMap { place -> (id: String, stationCode: Int)? in
            guard let code = Int(place.code) else { return nil }
            let stationCode = TMBPlaceParser.stationCode(forPlaceCode: code, name: place.name, in: feed)
            return (place.id, stationCode)
        }
        guard !requested.isEmpty else { return [:] }
        let fetched = try await metroArrivals(
            lineCode: lineCode,
            stationCodes: requested.map(\.stationCode)
        )
        var result: [String: [Arrival]] = [:]
        for item in requested {
            if let arrivals = fetched[item.stationCode] {
                result[item.id] = arrivals
            }
        }
        return result
    }

    /// Current metro service alerts.
    /// GET /alerts/metro/channels/WEB
    func alerts() async throws -> [ServiceAlert] {
        let data = try await get(path: "alerts/metro/channels/WEB")
        return try AlertParser.alerts(from: data)
    }

    // MARK: - Transport

    /// One line's station feed, cached for the process: the code bridge of
    /// `metroArrivals(lineCode:places:)` asks for it on every arrivals pass.
    /// An empty answer is not cached, so a failed fetch is retried next pass.
    /// `Place.lineCodes` holds display names ("L1") while the path needs the
    /// `CODI_LINIA` ("1"), so a display name is mapped to its code first.
    @MainActor func stationFeed(lineCode: String) async -> [Station] {
        let code = MetroLine.allLines.first { $0.displayName == lineCode }?.code ?? lineCode
        if let cached = stationFeedCache[code] { return cached }
        guard let stations = try? await stations(lineCode: code), !stations.isEmpty else { return [] }
        stationFeedCache[code] = stations
        return stations
    }

    /// Credentialed GET shared by the metro and bus endpoints; bus requests
    /// live in `TMBClient+Bus.swift`, which needs it visible across files.
    func get(path: String) async throws -> Data {
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
