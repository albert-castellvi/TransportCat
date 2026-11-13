import Foundation
import Compression

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Errors of the Rodalies feeds.
enum RodaliesError: Error, LocalizedError {
    case invalidURL
    case httpStatus(Int)
    case unexpectedPayload(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid Rodalies URL."
        case .httpStatus(let code):
            return "Rodalies responded with HTTP \(code)."
        case .unexpectedPayload(let reason):
            return "Unexpected Rodalies payload: \(reason)."
        }
    }
}

/// Client for Renfe's open data: the two GTFS-Realtime JSON feeds and the
/// timetable pack published by CI.
///
/// No credentials, no key, no User-Agent requirement. The realtime feeds are
/// regenerated continuously on Renfe's side (about every 20 s), so a 30 s poll
/// is enough; the request timeout matches `TMBClient` and `FGCClient` so a
/// stalled request cannot freeze the poll for several cycles.
///
/// The timetable is a daily CI artefact, not a bundled resource: the app keeps
/// one gzip copy under `Caches/Network/` and refreshes it when that copy is
/// older than `scheduleRefreshSeconds`. A failed download is silent and keeps
/// the cached copy, like `ScheduleStore`.
final class RodaliesClient {
    /// Fetches the compressed timetable. Nil means failure; there is no other
    /// error channel on purpose. Injectable so the cache policy is testable.
    typealias FetchSchedule = @Sendable () async -> Data?

    /// Where CI publishes the timetable: an asset of the rolling release,
    /// public, no authentication.
    static let releaseBaseURL =
        "https://github.com/albert-castellvi/TransportCat/releases/download/rodalies-latest/"
    static let scheduleFileName = "rodalies-schedule.json.gz"
    /// Versioned `DiskCache` key: a pack format change must use a new key.
    static let scheduleCacheKey = "rodalies-schedule.v1"
    /// How long a cached timetable is trusted. Renfe reissues the feed daily
    /// and codes trip ids with the date, so a day-old pack no longer joins the
    /// live trains; refreshing twice a day keeps the two in step without
    /// downloading the pack on every launch.
    static let scheduleRefreshSeconds: TimeInterval = 12 * 3600
    static let requestTimeoutSeconds: TimeInterval = 10

    static let vehiclePositionsURL = URL(string: "https://gtfsrt.renfe.com/vehicle_positions.json")!
    static let tripUpdatesURL = URL(string: "https://gtfsrt.renfe.com/trip_updates.json")!

    private let session: URLSession
    private let cache: DiskCache
    private let fetchSchedule: FetchSchedule

    init(
        session: URLSession = .shared,
        cache: DiskCache = .shared,
        fetchSchedule: @escaping FetchSchedule = { await RodaliesClient.remoteSchedule() }
    ) {
        self.session = session
        self.cache = cache
        self.fetchSchedule = fetchSchedule
    }

    // MARK: - Realtime

    /// `vehicle_positions.json`, the Spain-wide live vehicle feed.
    func vehiclePositions() async throws -> Data {
        try await get(Self.vehiclePositionsURL)
    }

    /// `trip_updates.json`, the Spain-wide per-trip delays.
    func tripUpdates() async throws -> Data {
        try await get(Self.tripUpdatesURL)
    }

    private func get(_ url: URL) async throws -> Data {
        let request = URLRequest(url: url, timeoutInterval: Self.requestTimeoutSeconds)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RodaliesError.unexpectedPayload("no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw RodaliesError.httpStatus(http.statusCode)
        }
        return data
    }

    // MARK: - Timetable

    /// The timetable pack: the cached copy while it is fresh, otherwise a
    /// download. Nil only when there is no cached copy and the download fails.
    ///
    /// The bytes are validated by decoding before they replace the cache, so a
    /// truncated download costs nothing and the previous pack keeps working.
    func schedule(now: Date = Date()) async -> RodaliesSchedule? {
        let cached = cachedSchedule()
        if let cached,
           let savedAt = cache.savedAt(forKey: Self.scheduleCacheKey),
           now.timeIntervalSince(savedAt) < Self.scheduleRefreshSeconds {
            return cached
        }
        guard let compressed = await fetchSchedule(),
              let schedule = Self.decodeSchedule(compressed) else {
            return cached
        }
        cache.saveInBackground(
            RodaliesScheduleEnvelope(data: compressed),
            forKey: Self.scheduleCacheKey
        )
        return schedule
    }

    /// The cached timetable, if there is one. Used by the store's tests and by
    /// callers that want the last known pack without touching the network.
    func cachedSchedule() -> RodaliesSchedule? {
        guard let envelope = cache.load(RodaliesScheduleEnvelope.self, forKey: Self.scheduleCacheKey) else {
            return nil
        }
        return Self.decodeSchedule(envelope.data)
    }

    /// Gzip bytes to a pack. The decoder is `RodaliesGzip`, and every failure
    /// (bad gzip, bad JSON, unknown version) is the same nil.
    static func decodeSchedule(_ compressed: Data) -> RodaliesSchedule? {
        guard let json = RodaliesGzip.decompress(compressed) else { return nil }
        return RodaliesSchedule.decode(json)
    }

    /// Default transport: a plain GET of the published asset. Any non-200, an
    /// empty body or a transport error is the same silent nil.
    static func remoteSchedule() async -> Data? {
        guard let url = URL(string: releaseBaseURL + scheduleFileName) else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return data.isEmpty ? nil : data
        } catch {
            return nil
        }
    }

    /// What the cache holds: the compressed pack and nothing else. Stored
    /// through `DiskCache`, which writes JSON, so the bytes travel base64.
    private struct RodaliesScheduleEnvelope: Codable, Sendable {
        let data: Data
    }
}

/// Gzip decompression for the published timetable, Foundation only.
///
/// `Compression` decodes raw DEFLATE, not the gzip wrapper, so the 10-byte
/// header (plus its optional fields) is walked here and the trailer's `ISIZE`
/// gives the exact output size. That way one `compression_decode_buffer` pass
/// is enough: no streaming, no growing buffer, no third-party dependency.
enum RodaliesGzip {
    /// Decompresses one gzip member, or nil when the bytes are not gzip or the
    /// deflate stream cannot be inflated.
    static func decompress(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count > 18, bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 8 else { return nil }
        let flags = bytes[3]
        var offset = 10
        // FEXTRA: 2-byte length, then that many bytes.
        if flags & 0x04 != 0 {
            guard offset + 2 <= bytes.count else { return nil }
            let length = Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
            offset += 2 + length
        }
        // FNAME and FCOMMENT: NUL-terminated strings.
        for flag in [UInt8(0x08), UInt8(0x10)] where flags & flag != 0 {
            while offset < bytes.count, bytes[offset] != 0 { offset += 1 }
            offset += 1
        }
        // FHCRC: 2-byte header checksum.
        if flags & 0x02 != 0 { offset += 2 }
        let trailer = bytes.count - 8
        guard offset < trailer else { return nil }
        // The footer is the CRC-32 and then ISIZE, the uncompressed size modulo
        // 2^32, little endian: the last four bytes of the member.
        let isize = bytes.count - 4
        let size = Int(bytes[isize]) | (Int(bytes[isize + 1]) << 8)
            | (Int(bytes[isize + 2]) << 16) | (Int(bytes[isize + 3]) << 24)
        guard size > 0 else { return nil }
        let payload = data.subdata(in: offset..<trailer)
        var output = [UInt8](repeating: 0, count: size)
        let written = payload.withUnsafeBytes { raw -> Int in
            guard let source = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_decode_buffer(
                &output, size, source, payload.count, nil, COMPRESSION_ZLIB
            )
        }
        guard written == size else { return nil }
        return Data(output)
    }
}
