import XCTest
@testable import TransportCat

/// Fixture loading helper for the TransportCatTests bundle.
enum Fixtures {
    static func data(_ name: String) throws -> Data {
        let bundle = Bundle(for: BundleToken.self)
        guard let url = bundle.url(forResource: name, withExtension: "json") else {
            XCTFail("Missing fixture \(name).json")
            throw TMBError.unexpectedPayload("missing fixture \(name)")
        }
        return try Data(contentsOf: url)
    }
}

private final class BundleToken {}

final class TMBClientDecodingTests: XCTestCase {
    func testStationsDecodeSortedByOrder() throws {
        let data = try Fixtures.data("stations-L1")
        let stations = try GeoJSONParser.stations(from: data, lineCode: "1")
        XCTAssertEqual(stations.count, 3)
        XCTAssertEqual(stations.map(\.name), ["Hospital de Bellvitge", "Bellvitge", "Av. Carrilet"])
        XCTAssertEqual(stations.map(\.orderInLine), [1, 2, 3])
        XCTAssertEqual(stations[0].code, 111)
        XCTAssertEqual(stations[0].latitude, 41.34467731, accuracy: 1e-8)
        XCTAssertEqual(stations[0].longitude, 2.10724192, accuracy: 1e-8)
        XCTAssertEqual(stations[0].accessible, true)
        XCTAssertEqual(stations[0].id, 81)
    }

    /// L9/L10/FM features carry only the minimal property set: the decode
    /// must still succeed with nil id and nil accessibility.
    func testStationsDecodeMinimalProperties() throws {
        let json = """
        {"features":[
          {"properties":{"CODI_ESTACIO":930,"NOM_ESTACIO":"La Sagrera","ORDRE_ESTACIO":1,"CODI_LINIA":"9N","NOM_LINIA":"L9N"},
           "geometry":{"type":"Point","coordinates":[2.186723,41.420494]}}
        ]}
        """.data(using: .utf8)!
        let stations = try GeoJSONParser.stations(from: json, lineCode: "9N")
        XCTAssertEqual(stations.count, 1)
        XCTAssertNil(stations[0].id)
        XCTAssertNil(stations[0].accessible)
        XCTAssertEqual(stations[0].name, "La Sagrera")
    }

    func testGeometryDecodesMultiLineString() throws {
        let data = try Fixtures.data("tram-L1")
        let geometry = try GeoJSONParser.geometry(from: data)
        XCTAssertEqual(geometry.points.count, 5)
        XCTAssertEqual(geometry.points[0], GeoPoint(latitude: 41.3437, longitude: 2.1068))
        XCTAssertEqual(geometry.points[4], GeoPoint(latitude: 41.3575, longitude: 2.1153))
    }

    func testArrivalsDecodeNumericAndTextualMin() throws {
        let data = try Fixtures.data("ibus-stop")
        let arrivals = try IBusParser.arrivals(from: data, lineCode: "1", stationCode: 113)
        XCTAssertEqual(arrivals.count, 3)
        // "2" (string) -> 120 s
        XCTAssertEqual(arrivals[0].seconds, 120)
        // 5 (int) -> 300 s
        XCTAssertEqual(arrivals[1].seconds, 300)
        // "Aprox." -> nil, never a crash
        XCTAssertNil(arrivals[2].seconds)
        XCTAssertEqual(arrivals[0].rawText, "2 min")
        XCTAssertEqual(arrivals[0].destination, "Fondo")
        XCTAssertEqual(arrivals[0].stationCode, 113)
    }

    func testAlertsDecodeTolerantEntities() throws {
        let data = try Fixtures.data("alerts")
        let alerts = try AlertParser.alerts(from: data)
        XCTAssertEqual(alerts.count, 2)
        XCTAssertEqual(alerts[0].id, "alert-001")
        XCTAssertEqual(alerts[0].lineCodes, ["2"])
        XCTAssertEqual(alerts[0].stationNames, ["La Pau", "Verneda"])
        let begin = try XCTUnwrap(alerts[0].beginDate)
        let end = try XCTUnwrap(alerts[0].endDate)
        XCTAssertEqual(begin.timeIntervalSince1970, 1793272800.0, accuracy: 0.001)
        XCTAssertEqual(end.timeIntervalSince1970, 1796351400.0, accuracy: 0.001)
        // Second alert: numeric line code and no end date, missing id.
        XCTAssertEqual(alerts[1].lineCodes, ["1"])
        XCTAssertNil(alerts[1].endDate)
        XCTAssertFalse(alerts[1].id.isEmpty)
    }

    func testMalformedPayloadsThrow() {
        XCTAssertThrowsError(try GeoJSONParser.stations(from: Data("{}".utf8), lineCode: "1"))
        XCTAssertThrowsError(try GeoJSONParser.geometry(from: Data("{}".utf8)))
        XCTAssertThrowsError(try IBusParser.arrivals(from: Data("{}".utf8), lineCode: "1", stationCode: 1))
        XCTAssertThrowsError(try AlertParser.alerts(from: Data("{}".utf8)))
    }
}
