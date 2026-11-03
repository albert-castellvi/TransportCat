import Foundation

/// JSON disk cache under `Caches/Network/` for the network payloads the app can
/// rebuild (spec S3).
///
/// Writes are atomic, so a killed app never leaves a half file behind, and
/// every failure is silent: the cache is an optimization, never a source of
/// errors. The save date is the file modification date, so callers can check
/// how old a cached copy is without a second file.
final class DiskCache {
    /// Shared cache used by the catalog stores.
    static let shared = DiskCache()

    /// Folder holding one `<key>.json` per value.
    let directory: URL

    /// - Parameter directory: cache folder. Defaults to `Caches/Network/`,
    ///   which the system may evict; the next launch simply loads again.
    init(directory: URL = DiskCache.defaultDirectory) {
        self.directory = directory
    }

    /// `Caches/Network/`.
    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base
            .appendingPathComponent("Network", isDirectory: true)
    }

    /// Encodes `value` and writes it atomically. Returns whether the write
    /// happened; a bad key or an encoding error is reported as `false` and has
    /// no other effect.
    @discardableResult
    func save<T: Encodable>(_ value: T, forKey key: String) -> Bool {
        guard let url = fileURL(forKey: key) else { return false }
        return Self.write(value, to: url)
    }

    /// Encodes `value` and writes it on a detached utility task, so a caller
    /// that just published the values it is saving never waits for the JSON
    /// encode and the disk write (spec S5).
    ///
    /// The write is atomic and just as silent as `save(_:forKey:)`; nil means
    /// the key cannot address a file. The returned task is for tests, which
    /// have to wait for it before reading the file back.
    @discardableResult
    func saveInBackground<T: Encodable & Sendable>(
        _ value: T,
        forKey key: String
    ) -> Task<Void, Never>? {
        guard let url = fileURL(forKey: key) else { return nil }
        return Task.detached(priority: .utility) {
            Self.write(value, to: url)
        }
    }

    /// Encodes one value and writes it atomically, creating its folder. Static
    /// so a detached save never captures the (non-`Sendable`) cache object.
    @discardableResult
    private static func write<T: Encodable>(_ value: T, to url: URL) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return false }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: url, options: [.atomic])
            return true
        } catch {
            return false
        }
    }

    /// Decodes the value stored under `key`, or nil when it is absent or does
    /// not decode. A corrupt file is never repaired here: the caller's next
    /// successful load overwrites it.
    func load<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let url = fileURL(forKey: key),
              let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    /// When the value under `key` was written, or nil when it is absent.
    func savedAt(forKey key: String) -> Date? {
        guard let url = fileURL(forKey: key) else { return nil }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attributes?[.modificationDate] as? Date
    }

    /// Deletes the value under `key`. Returns whether a file was removed.
    @discardableResult
    func remove(forKey key: String) -> Bool {
        guard let url = fileURL(forKey: key) else { return false }
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        return (try? FileManager.default.removeItem(at: url)) != nil
    }

    /// Whether a value is stored under `key` (whether or not it decodes).
    func hasValue(forKey key: String) -> Bool {
        guard let url = fileURL(forKey: key) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - Keys

    /// Maps a key to `<directory>/<key>.json`. Keys are restricted to letters,
    /// digits, dot, underscore and dash, and cannot start with a dot, so a bad
    /// key can never escape the cache folder.
    private func fileURL(forKey key: String) -> URL? {
        guard Self.isValidKey(key) else { return nil }
        return directory.appendingPathComponent("\(key).json", isDirectory: false)
    }

    static func isValidKey(_ key: String) -> Bool {
        guard !key.isEmpty, key.first != "." else { return false }
        return key.allSatisfy { character in
            character.isASCII && (character.isLetter || character.isNumber || character == "." || character == "_" || character == "-")
        }
    }
}
