import XCTest
@testable import TransportCat

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// URLProtocol stub for the FGC client: answers the paged stop request without
/// touching the network, like `MockURLProtocol` does for TMB.
final class FGCMockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = FGCMockURLProtocol.requestHandler else {
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

/// Network behaviour of `FGCClient` and the pure network rules of specs S2,
/// S4 and S5: paging, aliases, stop-code join, snapping and gliding.
final class FGCNetworkTests: XCTestCase {
    // MARK: - S1: client paging

    /// `limit` is capped at 100, so the 305 stops arrive in pages until one
    /// page is short. The client must ask offsets 0, 100, 200, 300 and stop.
    func testStopsPagingRequestsSequentialOffsetsAndStopsOnShortPage() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FGCMockURLProtocol.self]
        let client = FGCClient(session: URLSession(configuration: configuration))

        var seenOffsets: [Int] = []
        var seenTimeouts: [TimeInterval] = []
        var seenPaths: [String] = []
        FGCMockURLProtocol.requestHandler = { request in
            let url = try XCTUnwrap(request.url)
            seenTimeouts.append(request.timeoutInterval)
            seenPaths.append(url.path)
            let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
            let offset = Int(components.queryItems?.first { $0.name == "offset" }?.value ?? "0") ?? 0
            seenOffsets.append(offset)
            let limit = Int(components.queryItems?.first { $0.name == "limit" }?.value ?? "0") ?? 0
            XCTAssertEqual(limit, 100)

            // Three full pages and a short one: 305 rows.
            let count = offset < 300 ? 100 : 5
            let results: [[String: Any]] = (0..<count).map { index in
                [
                    "stop_id": "S\(offset + index)",
                    "stop_name": "Stop \(offset + index)",
                    "stop_coordinates": ["lon": 2.0, "lat": 41.0],
                ]
            }
            let payload: [String: Any] = ["total_count": 305, "results": results]
            let data = try JSONSerialization.data(withJSONObject: payload)
            let response = try XCTUnwrap(HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil, headerFields: nil
            ))
            return (response, data)
        }
        defer { FGCMockURLProtocol.requestHandler = nil }

        let stops = try await client.allStops()

        XCTAssertEqual(stops.count, 305)
        XCTAssertEqual(seenOffsets, [0, 100, 200, 300])
        XCTAssertEqual(seenPaths.count, 4)
        XCTAssertTrue(seenPaths.allSatisfy { $0.contains("/datasets/gtfs_stops/records") })
        XCTAssertEqual(seenTimeouts, Array(repeating: FGCClient.requestTimeoutSeconds, count: 4))
        XCTAssertEqual(FGCClient.requestTimeoutSeconds, 10)
        XCTAssertEqual(FGCClient.baseURL, "https://dadesobertes.fgc.cat/api/explore/v2.1/catalog/datasets")
        XCTAssertEqual(stops.first?.id, "S0")
        XCTAssertEqual(stops.last?.id, "S304")
    }

    func testLiveTrainsRequestUsesThePositionsDataset() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FGCMockURLProtocol.self]
        let client = FGCClient(session: URLSession(configuration: configuration))

        var seenURL: URL?
        FGCMockURLProtocol.requestHandler = { request in
            seenURL = request.url
            let payload = #"{"results":[{"id":"t1","lin":"S1","geo_point_2d":{"lon":2.15,"lat":41.39},"dir":"A","origen":"PC","desti":"NA","properes_parades":"{\"parada\": \"NA\"}","estacionat_a":null,"en_hora":"True","tipus_unitat":"112"}]}"#
            let response = try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil
            ))
            return (response, Data(payload.utf8))
        }
        defer { FGCMockURLProtocol.requestHandler = nil }

        let trains = try await client.liveTrains()

        XCTAssertEqual(trains.map(\.id), ["t1"])
        let url = try XCTUnwrap(seenURL)
        XCTAssertTrue(url.path.contains("/datasets/posicionament-dels-trens/records"))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.queryItems?.first { $0.name == "limit" }?.value, "100")
    }

    // MARK: - S4: aliases and neutral colour

    func testLineAliasesMapToTheBaseLine() {
        XCTAssertEqual(FGCNetwork.baseLineCode(for: "R5R"), "R5")
        XCTAssertEqual(FGCNetwork.baseLineCode(for: "R6R"), "R6")
        XCTAssertEqual(FGCNetwork.baseLineCode(for: "R61"), "R6")
        XCTAssertEqual(FGCNetwork.baseLineCode(for: "R62"), "R6")
        XCTAssertEqual(FGCNetwork.baseLineCode(for: "S1"), "S1")
    }

    func testAliasKeepsBaseColorAndLabel() {
        let lines = [
            FGCLine(code: "R5", name: "Manresa", colorHex: "3DBFC3", textColorHex: "FFFFFF", polylines: []),
            FGCLine(code: "R6", name: "Igualada", colorHex: "B3B3B3", textColorHex: "FFFFFF", polylines: []),
        ]
        let r5r = FGCNetwork.style(for: "R5R", in: lines)
        XCTAssertEqual(r5r.lineCode, "R5")
        XCTAssertEqual(r5r.label, "R5")
        XCTAssertEqual(r5r.colorHex, "3DBFC3")

        let r61 = FGCNetwork.style(for: "R61", in: lines)
        XCTAssertEqual(r61.lineCode, "R6")
        XCTAssertEqual(r61.colorHex, "B3B3B3")
    }

    func testUnknownLineFallsBackToNeutralGrayWithItsOwnLabel() {
        let lines = [
            FGCLine(code: "R5", name: "Manresa", colorHex: "3DBFC3", textColorHex: "FFFFFF", polylines: []),
        ]
        let m1 = FGCNetwork.style(for: "M1", in: lines)
        XCTAssertEqual(m1.lineCode, "M1")
        XCTAssertEqual(m1.label, "M1")
        XCTAssertEqual(m1.colorHex, "8E8E93")
        XCTAssertEqual(m1.textColorHex, "FFFFFF")

        let m2 = FGCNetwork.style(for: "M2", in: lines)
        XCTAssertEqual(m2.label, "M2")
        XCTAssertEqual(m2.colorHex, "8E8E93")
    }

    // MARK: - S5: snapping, heading and gliding

    /// North for ~1.1 km, then east for ~1.7 km.
    private var geometry: FGCLineGeometry {
        FGCNetwork.geometry(polylines: [[
            GeoPoint(latitude: 41.0, longitude: 2.0),
            GeoPoint(latitude: 41.01, longitude: 2.0),
            GeoPoint(latitude: 41.01, longitude: 2.02),
        ]])
    }

    func testGPSPointIsSnappedOntoThePolyline() throws {
        // ~42 m east of the north segment.
        let raw = GeoPoint(latitude: 41.005, longitude: 2.0005)
        let projection = try XCTUnwrap(FGCNetwork.snap(raw, in: geometry))

        XCTAssertEqual(projection.point.longitude, 2.0, accuracy: 1e-9)
        XCTAssertEqual(projection.point.latitude, 41.005, accuracy: 1e-9)
        XCTAssertEqual(projection.offsetMeters, 42, accuracy: 2)
        XCTAssertEqual(projection.polylineIndex, 0)
        XCTAssertEqual(projection.distance, 555, accuracy: 20)
    }

    func testHeadingIsTheTrackBearingAtTheSnappedPoint() throws {
        let polyline = geometry.polylines[0]

        // On the north segment the track points north.
        let north = try XCTUnwrap(FGCNetwork.snap(
            GeoPoint(latitude: 41.005, longitude: 2.0005), in: geometry
        ))
        XCTAssertEqual(north.heading, 0, accuracy: 0.5)

        // On the east segment the track points east.
        let east = try XCTUnwrap(FGCNetwork.snap(
            GeoPoint(latitude: 41.0101, longitude: 2.01), in: geometry
        ))
        XCTAssertEqual(east.heading, 90, accuracy: 0.5)
        XCTAssertEqual(
            FGCNetwork.heading(
                at: east.distance,
                points: polyline,
                cumulative: geometry.cumulative[0]
            ),
            east.heading,
            accuracy: 1e-9
        )
    }

    func testPointFartherThan300MetersKeepsNoProjection() {
        // ~840 m east of the line: too far to belong to it.
        let far = GeoPoint(latitude: 41.005, longitude: 2.01)
        XCTAssertNil(FGCNetwork.snap(far, in: geometry))
        XCTAssertNotNil(FGCNetwork.snap(far, in: geometry, maxOffsetMeters: 1_000))
    }

    func testGlideHalfwayThroughThePollIntervalIsAtTheMidDistance() {
        XCTAssertEqual(
            FGCNetwork.glide(from: 100, to: 300, elapsed: 15, duration: 30),
            200,
            accuracy: 1e-9
        )
        // Before and after the interval the value is clamped, never overshoots.
        XCTAssertEqual(FGCNetwork.glide(from: 100, to: 300, elapsed: -5, duration: 30), 100, accuracy: 1e-9)
        XCTAssertEqual(FGCNetwork.glide(from: 100, to: 300, elapsed: 45, duration: 30), 300, accuracy: 1e-9)
        XCTAssertEqual(FGCNetwork.glide(from: 100, to: 300, elapsed: 15, duration: 0), 300, accuracy: 1e-9)
    }

    /// A train moving toward lower polyline distances runs against the order the
    /// track was drawn in, so its marker faces the opposite way of the track
    /// bearing; a train that did not move keeps the side it had.
    func testTravelHeadingFollowsTheDirectionOfMotion() {
        let forward = FGCNetwork.travelHeading(track: 90, from: 100, to: 300, previouslyReversed: false)
        XCTAssertEqual(forward.heading, 90, accuracy: 1e-9)
        XCTAssertFalse(forward.reversed)

        let backward = FGCNetwork.travelHeading(track: 90, from: 300, to: 100, previouslyReversed: false)
        XCTAssertEqual(backward.heading, 270, accuracy: 1e-9)
        XCTAssertTrue(backward.reversed)

        let stopped = FGCNetwork.travelHeading(track: 90, from: 200, to: 200, previouslyReversed: true)
        XCTAssertEqual(stopped.heading, 270, accuracy: 1e-9)
        XCTAssertTrue(stopped.reversed)

        let wrapped = FGCNetwork.travelHeading(track: 270, from: 300, to: 100, previouslyReversed: false)
        XCTAssertEqual(wrapped.heading, 90, accuracy: 1e-9)
    }

    /// The drawn point belongs to the polyline at the glided distance, and its
    /// heading follows the same distance (a curve turns the marker).
    func testGlidedPointStaysOnThePolyline() throws {
        let polyline = geometry.polylines[0]
        let cumulative = geometry.cumulative[0]
        let start = 100.0
        let target = 900.0
        let middle = FGCNetwork.glide(from: start, to: target, elapsed: 15, duration: 30)

        let point = try XCTUnwrap(GeoMath.point(at: middle, points: polyline, cumulative: cumulative))
        let projection = try XCTUnwrap(FGCNetwork.snap(point, in: geometry))
        XCTAssertEqual(projection.offsetMeters, 0, accuracy: 0.5)
        XCTAssertEqual(projection.distance, middle, accuracy: 1)
        XCTAssertEqual(FGCNetwork.heading(at: middle, points: polyline, cumulative: cumulative), 0, accuracy: 0.5)
    }

    // MARK: - S11: shared layer values

    func testMapLineLayerAndVehicleCarryTheSharedFields() {
        let layer = MapLineLayer(
            id: "S1",
            operator: "FGC",
            code: "S1",
            colorHex: "EF7900",
            textColorHex: "FFFFFF",
            polylines: [[GeoPoint(latitude: 41, longitude: 2)]]
        )
        XCTAssertEqual(layer.id, "S1")
        XCTAssertEqual(layer.`operator`, "FGC")
        XCTAssertEqual(layer.code, "S1")
        XCTAssertEqual(layer.colorHex, "EF7900")

        let vehicle = MapVehicle(
            id: "t1",
            lineCode: "S1",
            colorHex: "EF7900",
            position: GeoPoint(latitude: 41, longitude: 2),
            heading: 90,
            label: "Terrassa"
        )
        XCTAssertEqual(vehicle.lineCode, "S1")
        XCTAssertEqual(vehicle.heading, 90)
    }
}
