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
            return (response, try Fixtures.data("ibus-stop"))
        }
        _ = try await client.arrivals(lineCode: "1", stopCode: 113)

        let url = try XCTUnwrap(capturedURL)
        XCTAssertEqual(url.absoluteString, "https://api.tmb.cat/v1/ibus/lines/1/stops/113?app_id=test-id&app_key=test-key")
    }

    func testLineGeometryRequestPath() async throws {
        var capturedPath: String?
        MockURLProtocol.requestHandler = { request in
            capturedPath = request.url?.path
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, try Fixtures.data("tram-L1"))
        }
        let geometry = try await client.lineGeometry(lineCode: "1")
        XCTAssertEqual(capturedPath, "/v1/transit/linies/metro/1/tram")
        XCTAssertEqual(geometry.points.count, 5)
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
