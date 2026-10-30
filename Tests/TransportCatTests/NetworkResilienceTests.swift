import XCTest
@testable import TransportCat

final class NetworkResilienceTests: XCTestCase {
    func testRequestsCarryTheShortTimeout() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = TMBClient(
            session: URLSession(configuration: configuration),
            credentials: TMBCredentials(appId: "id", appKey: "key")
        )
        var seenTimeout: TimeInterval?
        MockURLProtocol.requestHandler = { request in
            seenTimeout = request.timeoutInterval
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data("{\"timestamp\":0,\"linies\":[]}".utf8))
        }
        defer { MockURLProtocol.requestHandler = nil }

        _ = try await client.metroArrivals(lineCode: "1", stationCodes: [111])

        XCTAssertEqual(seenTimeout, TMBClient.requestTimeoutSeconds)
        XCTAssertEqual(TMBClient.requestTimeoutSeconds, 10)
    }

    func testTransientNetworkFailures() {
        for code: URLError.Code in [.timedOut, .notConnectedToInternet, .networkConnectionLost, .cancelled] {
            XCTAssertTrue(URLError(code).isTransientNetworkFailure, "\(code)")
        }
        XCTAssertFalse(URLError(.badServerResponse).isTransientNetworkFailure)
        XCTAssertFalse(TMBError.httpStatus(500).isTransientNetworkFailure)
    }

    func testRedactorHidesCredentialsInTheSentryError() {
        let text = "Error Domain=NSURLErrorDomain Code=-1001 NSErrorFailingURLStringKey=https://api.tmb.cat/v1/itransit/metro/estacions?estacions=509,510&app_id=aaaa1111&app_key=bbbb2222cccc3333dddd4444eeee5555, NSErrorFailingURLKey=https://api.tmb.cat/v1/x?app_id=aaaa1111&app_key=bbbb2222cccc3333dddd4444eeee5555)"
        let redacted = SecretRedactor.redact(text)

        XCTAssertFalse(redacted.contains("aaaa1111"))
        XCTAssertFalse(redacted.contains("bbbb2222"))
        XCTAssertTrue(redacted.contains("estacions=509,510&app_id=[redacted]&app_key=[redacted], NSErrorFailingURLKey="))
        XCTAssertEqual(SecretRedactor.redact("no secrets here"), "no secrets here")
    }
}
