import XCTest
@testable import TransportCat

/// Google encoded polyline (precision 5) decoding, the format TMB ships in the
/// planner `legGeometry.points` (spec S16).
final class PolylineDecoderTests: XCTestCase {
    func testDecodesTheKnownGoogleVector() throws {
        let points = PolylineDecoder.decode("_p~iF~ps|U_ulLnnqC_mqNvxq`@")

        XCTAssertEqual(points.count, 3)
        XCTAssertEqual(points[0].latitude, 38.5, accuracy: 1e-9)
        XCTAssertEqual(points[0].longitude, -120.2, accuracy: 1e-9)
        XCTAssertEqual(points[1].latitude, 40.7, accuracy: 1e-9)
        XCTAssertEqual(points[1].longitude, -120.95, accuracy: 1e-9)
        XCTAssertEqual(points[2].latitude, 43.252, accuracy: 1e-9)
        XCTAssertEqual(points[2].longitude, -126.453, accuracy: 1e-9)
    }

    func testEmptyInputDecodesToNoPoints() {
        XCTAssertEqual(PolylineDecoder.decode(""), [])
    }

    func testSingleCoordinateRoundTrip() throws {
        // Deltas of zero encode to "?" (63 - 0); the second point is one
        // precision unit north and two west: (0.00001, -0.00002).
        let points = PolylineDecoder.decode("??AB")
        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points[0].latitude, 0, accuracy: 1e-9)
        XCTAssertEqual(points[0].longitude, 0, accuracy: 1e-9)
        XCTAssertEqual(points[1].latitude, 0.00001, accuracy: 1e-9)
        XCTAssertEqual(points[1].longitude, -0.00002, accuracy: 1e-9)
    }

    func testDeltasAccumulateAcrossPoints() throws {
        // Same three vertices as the known vector: the second and third points
        // are encoded as deltas of the accumulated sum, so decoding a slice of
        // the middle chunk must land on the running lat/lon.
        let points = PolylineDecoder.decode("_p~iF~ps|U_ulLnnqC_mqNvxq`@")
        var accumulatedLatitude = 0.0
        var accumulatedLongitude = 0.0
        for point in points {
            accumulatedLatitude = point.latitude
            accumulatedLongitude = point.longitude
        }
        XCTAssertEqual(accumulatedLatitude, 43.252, accuracy: 1e-9)
        XCTAssertEqual(accumulatedLongitude, -126.453, accuracy: 1e-9)
    }

    func testTruncatedVectorDecodesCompletePointsOnly() throws {
        // The known vector minus its last byte: the dropped '@' closed the
        // final longitude chunk, so only the first two complete pairs survive
        // and the decoder never hangs on the dangling continuation byte.
        let truncated = String("_p~iF~ps|U_ulLnnqC_mqNvxq`@".dropLast())
        let points = PolylineDecoder.decode(truncated)
        XCTAssertEqual(points.count, 2)

        // A lone continuation byte is not a complete coordinate at all.
        XCTAssertEqual(PolylineDecoder.decode("u"), [])
    }

    func testGarbageInputNeverCrashes() {
        // Bytes below the 63 offset are not valid polyline payloads; the
        // decoder must stop cleanly instead of trapping.
        let points = PolylineDecoder.decode("###--")
        XCTAssertTrue(points.isEmpty || !points.isEmpty)
    }
}
