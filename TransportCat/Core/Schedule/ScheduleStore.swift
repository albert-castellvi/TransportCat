import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Fetches and caches the schedule pack published by CI (spec S2b).
///
/// The app does not bundle a timetable: a daily workflow builds the pack from
/// TMB's static GTFS and publishes it as assets of the rolling `schedule-latest`
/// release, and this store keeps a copy under `Caches/Schedule/`. Only the line
/// the user opens is downloaded, and only when the cache has no copy of it or
/// its copy comes from an older feed.
///
/// The rules are deliberate:
/// - nothing is replaced before the new bytes decoded, so a truncated download
///   costs nothing and the previous pack keeps working;
/// - every failure is silent: no error, no retry storm, the feature stays off;
/// - writing is atomic, so a killed app never leaves a half file behind;
/// - the network is one injectable closure, so the cache logic is testable and
///   the pure decoding stays in `SchedulePack`.
final class ScheduleStore: Sendable {
    /// Fetches one file of the pack by its name in the index. Nil means
    /// failure; there is no other error channel on purpose.
    typealias Fetch = @Sendable (_ file: String) async -> Data?

    /// Where CI publishes the pack: the assets of the rolling release, public,
    /// no authentication.
    static let remoteBaseURL =
        "https://github.com/albert-castellvi/TransportCat/releases/download/schedule-latest/"

    static let shared = ScheduleStore()

    private static let indexFile = "index.json"
    private static let versionSuffix = ".version"

    /// Folder holding the cached pack.
    let directory: URL

    private let fetch: Fetch

    /// - Parameters:
    ///   - directory: cache folder. Defaults to `Caches/Schedule/`.
    ///   - fetch: transport, injectable for tests.
    init(directory: URL = ScheduleStore.defaultDirectory, fetch: @escaping Fetch = { file in
        await ScheduleStore.remote(file: file)
    }) {
        self.directory = directory
        self.fetch = fetch
    }

    /// `Caches/Schedule/`. A cache folder, so the system may evict it and the
    /// next launch simply downloads the pack again.
    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent("Schedule", isDirectory: true)
    }

    /// The line of the pack, decoded from the cache, or downloaded and cached
    /// when the cache has no current copy. Nil when the pack is unavailable:
    /// the caller then simply does not show a timetable.
    ///
    /// Concurrent calls for the same line may download it twice; the writes are
    /// atomic and idempotent, so the cost is one wasted request, never a
    /// corrupt cache.
    func line(mode: ScheduleMode, code: Int) async -> ScheduleLine? {
        var pack = cachedPack()
        if pack == nil {
            // First launch: nothing is cached yet, and the refresh fired at
            // start-up may not have finished. One index request is cheap, and
            // the index is the refresh's answer instead of a second read of a
            // file whose write runs in the background (spec S5).
            pack = await refreshIndex() ?? cachedPack()
        }
        guard let pack,
              let file = pack.fileName(mode: mode, code: code),
              Self.isPackFileName(file) else { return nil }

        if let cached = cachedLine(pack, file: file) { return cached }

        guard let data = await fetch(file),
              let line = try? ScheduleLine.decode(data, timeZone: pack.timeZone),
              line.mode == mode,
              line.code == code else { return nil }

        store(data, file: file, version: pack.feedVersion)
        return line
    }

    /// Plain GET of `index.json`, once per launch: it is a few kilobytes, and a
    /// release asset redirects to a CDN, which makes conditional requests
    /// unreliable. When the feed identity did not change nothing is rewritten;
    /// when it did, every line file of the old feed is stale and gets replaced
    /// the next time it is requested (see `cachedLine`).
    ///
    /// - Returns: the index that is in force now, so a caller that needs it in
    ///   this same launch does not have to wait for the background write of the
    ///   file (spec S5).
    @discardableResult
    func refreshIndex() async -> SchedulePack? {
        guard let data = await fetch(Self.indexFile), let incoming = decodeIndex(data) else { return nil }
        if let current = cachedPack(),
           current.feedVersion == incoming.feedVersion,
           current.generatedAt == incoming.generatedAt {
            return incoming
        }
        writeInBackground(data, to: url(Self.indexFile))
        return incoming
    }

    // MARK: - Cache

    private func cachedPack() -> SchedulePack? {
        guard let data = data(of: Self.indexFile) else { return nil }
        return decodeIndex(data)
    }

    /// The index as a pack, or nil when it does not decode or its version is
    /// not one this code understands. Validation happens here, before anything
    /// cached is replaced: an unexpected payload must not cost a working pack.
    private func decodeIndex(_ data: Data) -> SchedulePack? {
        // The store decodes line files itself, so the pack built here is only
        // the index: names, time zone and feed identity.
        try? SchedulePack(index: data) { _ in nil }
    }

    /// The cached copy of a line file, or nil when it is missing or was
    /// downloaded for a different `feedVersion`.
    private func cachedLine(_ pack: SchedulePack, file: String) -> ScheduleLine? {
        guard let data = data(of: file) else { return nil }
        if let version = pack.feedVersion, storedVersion(of: file) != version { return nil }
        return try? ScheduleLine.decode(data, timeZone: pack.timeZone)
    }

    /// Bytes of a cached file, or nil when it is not there.
    private func data(of file: String) -> Data? {
        guard Self.isPackFileName(file) else { return nil }
        return try? Data(contentsOf: url(file))
    }

    private func storedVersion(of file: String) -> String? {
        guard let data = data(of: file + Self.versionSuffix) else { return nil }
        let value = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func store(_ data: Data, file: String, version: String?) {
        guard Self.isPackFileName(file) else { return }
        // The line file goes first: if the app dies in between, the version
        // marker still names the older feed and the file is downloaded again.
        // Both writes share one task, so that order holds off the caller's
        // actor (spec S5).
        let fileURL = url(file)
        let versionURL = url(file + Self.versionSuffix)
        let versionData = Data((version ?? "").utf8)
        Task.detached(priority: .utility) {
            Self.writeData(data, to: fileURL)
            Self.writeData(versionData, to: versionURL)
        }
    }

    /// Writes one file of the pack on a detached utility task (spec S5): the
    /// caller already decoded what it needs, so it never waits for the bytes to
    /// reach the disk.
    private func writeInBackground(_ data: Data, to url: URL) {
        Task.detached(priority: .utility) {
            Self.writeData(data, to: url)
        }
    }

    /// Atomic write: the temporary file lives next to the target and is renamed
    /// into place, so a reader never sees a partial file. Static so a detached
    /// task never captures the store.
    private static func writeData(_ data: Data, to url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }

    private func url(_ file: String) -> URL {
        directory.appendingPathComponent(file, isDirectory: false)
    }

    /// A pack file name must stay inside the cache folder: it comes from a
    /// remote index, and a path in it must never address anything else.
    static func isPackFileName(_ file: String) -> Bool {
        !file.isEmpty
            && file != "."
            && file != ".."
            && !file.contains("/")
            && !file.contains("\\")
    }

    // MARK: - Transport

    /// Default transport: a plain GET of the published asset. Any non-200, an
    /// empty body or a transport error is the same silent nil.
    static func remote(file: String) async -> Data? {
        guard isPackFileName(file),
              let url = URL(string: remoteBaseURL + file) else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return data.isEmpty ? nil : data
        } catch {
            return nil
        }
    }
}
