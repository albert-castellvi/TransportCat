import XCTest
@testable import TransportCat

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// URLProtocol stub whose every request fails, counting how many the store
/// actually attempts: a retry must reach the network again.
final class FailingURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var attempts = 0

    static func reset() {
        lock.lock()
        attempts = 0
        lock.unlock()
    }

    static var attemptCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return attempts
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.attempts += 1
        Self.lock.unlock()
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    override func stopLoading() {}
}

/// Launch behaviour of the place catalog store (#66): a failed first load
/// without a cached copy must be retryable, not cached as an empty catalog for
/// the rest of the launch.
@MainActor
final class PlaceCatalogStoreTests: XCTestCase {
    func testFailedEmptyLoadCanBeRetried() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("TransportCatPlaceCatalogStoreTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FailingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let tmb = TMBClient(
            session: session,
            credentials: TMBCredentials(appId: "test-id", appKey: "test-key")
        )
        let store = PlaceCatalogStore(cache: DiskCache(directory: directory))

        FailingURLProtocol.reset()
        let first = await store.load(client: tmb, fgcClient: FGCClient(session: session))
        XCTAssertFalse(first)
        XCTAssertTrue(store.places.isEmpty)
        let firstAttempts = FailingURLProtocol.attemptCount
        XCTAssertGreaterThan(firstAttempts, 0)

        let second = await store.load(client: tmb, fgcClient: FGCClient(session: session))
        XCTAssertFalse(second)
        XCTAssertGreaterThan(
            FailingURLProtocol.attemptCount,
            firstAttempts,
            "an attempt that ended empty must not consume the launch guard"
        )
    }
}
