import XCTest
@testable import TransportCat

/// Cache rules of the schedule pack (#85): an empty `feedVersion` in the index
/// means the same as an absent one, so a line downloaded for that pack stays
/// valid instead of hitting the network on every request.
final class ScheduleStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("TransportCatScheduleStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        try super.tearDownWithError()
    }

    private func write(_ json: String, as name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: directory.appendingPathComponent(name))
    }

    /// #85: the builder writes `feedVersion: ""` when the feed has none, and
    /// the cached line was then always treated as stale. The cache holds the
    /// pack in force, so no download may happen: the fetch always fails here.
    func testEmptyFeedVersionKeepsTheCachedLine() async throws {
        try write(
            """
            {"v":1,"generatedAt":"2026-10-30T00:00:00Z","feedVersion":"",\
            "feedStart":"20261030","feedEnd":"20261105","timezone":"Europe/Madrid",\
            "lines":[{"mode":"metro","code":94,"name":"L9N","file":"metro-94.json"}]}
            """,
            as: "index.json"
        )
        try write(
            """
            {"v":1,"mode":"metro","code":94,"name":"L9N","dates":{"20261030":0},\
            "directions":[{"id":0,"headsign":"Can Zam",\
            "patterns":[{"stops":[111,112],"arr":[0,60],"dep":[30,90]}],\
            "dayTypes":[[[36000,0]]]}]}
            """,
            as: "metro-94.json"
        )
        // The empty version marker the previous download left behind.
        try write("", as: "metro-94.json.version")

        let store = ScheduleStore(directory: directory, fetch: { _ in nil })
        let loaded = await store.line(mode: .metro, code: 94)
        let line = try XCTUnwrap(loaded)
        XCTAssertEqual(line.code, 94)
        XCTAssertEqual(line.name, "L9N")
    }

    /// A non-empty version still invalidates a file from another feed.
    func testADifferentFeedVersionMissesTheCache() async throws {
        try write(
            """
            {"v":1,"generatedAt":"2026-10-30T00:00:00Z","feedVersion":"feed-2",\
            "feedStart":"20261030","feedEnd":"20261105","timezone":"Europe/Madrid",\
            "lines":[{"mode":"metro","code":94,"name":"L9N","file":"metro-94.json"}]}
            """,
            as: "index.json"
        )
        try write(
            """
            {"v":1,"mode":"metro","code":94,"name":"L9N","dates":{"20261030":0},\
            "directions":[{"id":0,"headsign":"Can Zam",\
            "patterns":[{"stops":[111,112],"arr":[0,60],"dep":[30,90]}],\
            "dayTypes":[[[36000,0]]]}]}
            """,
            as: "metro-94.json"
        )
        try write("feed-1", as: "metro-94.json.version")

        let store = ScheduleStore(directory: directory, fetch: { _ in nil })
        let line = await store.line(mode: .metro, code: 94)
        XCTAssertNil(line, "a file of another feed must be downloaded again")
    }
}
