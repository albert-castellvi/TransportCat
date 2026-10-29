import Observation
import XCTest
@testable import TransportCat

/// URLProtocol mock: captures requests and replays fixture data.
final class MockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = MockURLProtocol.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class TMBClientTests: XCTestCase {
    private var client: TMBClient!

    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        client = TMBClient(
            session: URLSession(configuration: configuration),
            credentials: TMBCredentials(appId: "test-id", appKey: "test-key")
        )
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    private func stub(status: Int = 200, body: @escaping () throws -> Data) {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (response, try body())
        }
    }

    func testStationsRequestSucceedsAndDecodes() async throws {
        stub(body: { try Fixtures.data("stations-L1") })
        let stations = try await client.stations(lineCode: "1")
        XCTAssertEqual(stations.count, 3)
    }

    func testRequestURLContainsPathAndCredentials() async throws {
        var capturedURL: URL?
        MockURLProtocol.requestHandler = { request in
            capturedURL = request.url
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, try Fixtures.data("imetro-L1"))
        }
        _ = try await client.metroArrivals(lineCode: "1", stationCodes: [111, 112])

        let url = try XCTUnwrap(capturedURL)
        XCTAssertEqual(url.path, "/v1/itransit/metro/estacions")
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.queryItems, [
            URLQueryItem(name: "estacions", value: "111,112"),
            URLQueryItem(name: "app_id", value: "test-id"),
            URLQueryItem(name: "app_key", value: "test-key"),
        ])
    }

    func testLineGeometryRequestPath() async throws {
        var capturedPath: String?
        MockURLProtocol.requestHandler = { request in
            capturedPath = request.url?.path
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, try Fixtures.data("metro-line-L1"))
        }
        let geometry = try await client.lineGeometry(lineCode: "1")
        XCTAssertEqual(capturedPath, "/v1/transit/linies/metro/1")
        XCTAssertEqual(geometry.points.count, 5)
    }

    /// The line geometry endpoint can fail while the station list works: the
    /// stations must survive, the fallback polyline must keep the line
    /// drawable, and no error must be surfaced for the missing geometry.
    @MainActor
    func testTopologyKeepsStationsWhenGeometryFails() async throws {
        MockURLProtocol.requestHandler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/estacions") {
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    try Fixtures.data("stations-L1")
                )
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }

        let line = try XCTUnwrap(MetroLine.line(forCode: "1"))
        let state = LineState(line: line, client: client)
        await state.loadTopology()

        XCTAssertEqual(state.stations.map(\.code), [111, 112, 113])
        XCTAssertNotNil(state.engine)
        XCTAssertEqual(state.geometry?.points.count, 3)
        XCTAssertEqual(state.geometry?.points.first, GeoPoint(latitude: 41.34467731, longitude: 2.10724192))
        XCTAssertNil(state.errorMessage)
    }

    /// The screens hold LineState in an optional `@State`, so it must be
    /// `@Observable`: an `ObservableObject` there never redraws the map after
    /// the stations arrive (blank map in builds up to 11).
    @MainActor
    func testLoadedStationsNotifyObservers() async throws {
        MockURLProtocol.requestHandler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                try Fixtures.data("stations-L1")
            )
        }
        let line = try XCTUnwrap(MetroLine.line(forCode: "1"))
        let state = LineState(line: line, client: client)
        let changed = ChangeFlag()
        withObservationTracking {
            _ = state.stations
        } onChange: {
            changed.value = true
        }

        await state.loadTopology()

        XCTAssertTrue(changed.value)
        XCTAssertFalse(state.stations.isEmpty)
    }

    func testHTTPErrorSurfacesAsTMBError() async {
        stub(status: 403, body: { Data() })
        do {
            _ = try await client.stations(lineCode: "1")
            XCTFail("Expected httpStatus error")
        } catch let error as TMBError {
            XCTAssertEqual(error, .httpStatus(403))
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testCredentialsFromEmptyBundleThrow() {
        XCTAssertThrowsError(try TMBCredentials.fromBundle([:])) { error in
            XCTAssertEqual(error as? TMBError, .missingCredentials)
        }
    }

    func testCredentialsFromValidBundle() throws {
        let credentials = try TMBCredentials.fromBundle(["TMBAppId": "abc", "TMBAppKey": "def"])
        XCTAssertEqual(credentials, TMBCredentials(appId: "abc", appKey: "def"))
        XCTAssertFalse(credentials.isEmpty)
    }
}

/// Set from `withObservationTracking`'s `@Sendable` onChange closure.
private final class ChangeFlag: @unchecked Sendable {
    var value = false
}
