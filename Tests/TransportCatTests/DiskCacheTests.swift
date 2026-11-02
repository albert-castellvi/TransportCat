import XCTest
@testable import TransportCat

/// `DiskCache` (spec S3): JSON under `Caches/Network/`, atomic writes, silent
/// failures and a save date. Each test gets its own folder under the system
/// temporary directory.
final class DiskCacheTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("TransportCatDiskCacheTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        try super.tearDownWithError()
    }

    private func place(code: String, name: String) -> Place {
        Place(
            kind: .metroStation,
            code: code,
            name: name,
            position: GeoPoint(latitude: 41.385, longitude: 2.170),
            lineCodes: ["1"],
            accessible: true
        )
    }

    func testRoundtripOfCodableValues() {
        let cache = DiskCache(directory: directory)
        let places = [place(code: "1", name: "Catalunya"), place(code: "2", name: "Universitat")]

        XCTAssertTrue(cache.save(places, forKey: "places.v1"))
        XCTAssertEqual(cache.load([Place].self, forKey: "places.v1"), places)
    }

    func testRoundtripKeepsDates() {
        struct Entry: Codable, Equatable {
            let date: Date
            let name: String
        }
        let cache = DiskCache(directory: directory)
        let entry = Entry(date: Date(timeIntervalSince1970: 1_700_000_000), name: "avui")

        cache.save(entry, forKey: "entry")
        // JSON dates use whole seconds in ISO 8601; compare with a tolerance.
        let loaded = cache.load(Entry.self, forKey: "entry")
        XCTAssertEqual(loaded?.name, "avui")
        XCTAssertEqual(loaded!.date.timeIntervalSince1970, 1_700_000_000, accuracy: 1)
    }

    func testMissingKeyLoadsNil() {
        let cache = DiskCache(directory: directory)
        XCTAssertNil(cache.load([Place].self, forKey: "absent"))
        XCTAssertNil(cache.savedAt(forKey: "absent"))
    }

    func testSaveDateIsTheFileModificationDate() {
        let cache = DiskCache(directory: directory)
        let before = Date().addingTimeInterval(-1)
        cache.save([place(code: "1", name: "Catalunya")], forKey: "places.v1")

        let savedAt = cache.savedAt(forKey: "places.v1")
        XCTAssertNotNil(savedAt)
        XCTAssertGreaterThan(savedAt!, before)
        XCTAssertLessThan(savedAt!, Date().addingTimeInterval(5))
    }

    func testOverwritingReplacesTheValue() {
        let cache = DiskCache(directory: directory)
        cache.save([place(code: "1", name: "Vell")], forKey: "places.v1")
        cache.save([place(code: "2", name: "Nou")], forKey: "places.v1")

        XCTAssertEqual(cache.load([Place].self, forKey: "places.v1")?.map(\.name), ["Nou"])
    }

    func testCorruptPayloadLoadsNilInsteadOfThrowing() throws {
        let cache = DiskCache(directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: directory.appendingPathComponent("broken.json"))

        XCTAssertNil(cache.load([Place].self, forKey: "broken"))
    }

    func testInvalidKeysAreRejected() {
        let cache = DiskCache(directory: directory)
        XCTAssertFalse(cache.save([place(code: "1", name: "X")], forKey: "../escape"))
        XCTAssertFalse(cache.save([place(code: "1", name: "X")], forKey: "a/b"))
        XCTAssertFalse(cache.save([place(code: "1", name: "X")], forKey: ""))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("escape.json").path))
    }

    func testRemoveDeletesTheValue() {
        let cache = DiskCache(directory: directory)
        cache.save([place(code: "1", name: "X")], forKey: "places.v1")
        XCTAssertTrue(cache.remove(forKey: "places.v1"))
        XCTAssertNil(cache.load([Place].self, forKey: "places.v1"))
        XCTAssertFalse(cache.remove(forKey: "places.v1"))
    }
}
