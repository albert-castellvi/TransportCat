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
        // Live coordinates: Bunyol's Av. Carrilet is ~1 km from the old synthetic
        // pair, so the fixture now pins the real ones.
        XCTAssertEqual(stations[2].latitude, 41.35855331, accuracy: 1e-8)
        XCTAssertEqual(stations[2].longitude, 2.10263153, accuracy: 1e-8)
    }

    /// All 11 lines return `ID_ESTACIO` and `NOM_TIPUS_ACCESSIBILITAT` today,
    /// but the schema does not guarantee them: a payload without those keys
    /// must still decode to nil instead of failing.
    func testStationsDecodeToleratesMissingOptionalProperties() throws {
        let json = """
        {"features":[
          {"properties":{"CODI_ESTACIO":133,"NOM_ESTACIO":"La Sagrera","ORDRE_ESTACIO":23,"CODI_LINIA":1,"NOM_LINIA":"L1"},
           "geometry":{"type":"Point","coordinates":[2.18697533,41.42236877]}}
        ]}
        """.data(using: .utf8)!
        let stations = try GeoJSONParser.stations(from: json, lineCode: "1")
        XCTAssertEqual(stations.count, 1)
        XCTAssertNil(stations[0].id)
        XCTAssertNil(stations[0].accessible)
        XCTAssertEqual(stations[0].name, "La Sagrera")
    }

    func testGeometryDecodesFeatureCollectionMultiLineString() throws {
        let data = try Fixtures.data("metro-line-L1")
        let geometry = try GeoJSONParser.geometry(from: data)
        XCTAssertEqual(geometry.points.count, 5)
        XCTAssertEqual(geometry.points[0], GeoPoint(latitude: 41.34213332, longitude: 2.09846443))
        XCTAssertEqual(geometry.points[4], GeoPoint(latitude: 41.34178589, longitude: 2.10292525))
    }

    /// Live L1 capture: two vias of station 133 and one via of station 138.
    /// Countdowns are computed against the response `timestamp`, and the
    /// sub-minute case the app must render as "<1 min" is the first train of
    /// station 133 (1340 ms).
    func testMetroArrivalsDecodeLiveStations() throws {
        let data = try Fixtures.data("imetro-L1")
        let arrivals = try MetroParser.arrivals(from: data, lineCode: "1")
        XCTAssertEqual(Set(arrivals.keys), [133, 138])

        let sagrera = try XCTUnwrap(arrivals[133])
        XCTAssertEqual(sagrera.count, 3)
        XCTAssertEqual(sagrera[0].stationCode, 133)
        XCTAssertEqual(sagrera[0].lineCode, "1")
        XCTAssertEqual(sagrera[0].destination, "Fondo")
        XCTAssertEqual(sagrera[0].seconds, 1)
        XCTAssertEqual(sagrera[0].rawText, "<1 min")
        XCTAssertEqual(sagrera[0].serviceCode, "102")
        XCTAssertEqual(sagrera[1].seconds, 214)
        XCTAssertEqual(sagrera[1].rawText, "3 min")
        // Second via of the same station, opposite direction.
        XCTAssertEqual(sagrera[2].destination, "Hospital de Bellvitge")
        XCTAssertEqual(sagrera[2].seconds, 140)
        XCTAssertEqual(sagrera[2].rawText, "2 min")
        XCTAssertEqual(sagrera[2].serviceCode, "129")

        let baroDeViver = try XCTUnwrap(arrivals[138])
        XCTAssertEqual(baroDeViver.map(\.seconds), [142, 379])
        XCTAssertEqual(baroDeViver.map(\.rawText), ["2 min", "6 min"])

        // The live payload only carries the requested line: asking for another
        // line must not invent arrivals for it.
        XCTAssertTrue(try MetroParser.arrivals(from: data, lineCode: "5").isEmpty)

        // A station with no trains in the response keeps no entry.
        let empty = try MetroParser.arrivals(from: Data("{\"timestamp\":0,\"linies\":[]}".utf8), lineCode: "1")
        XCTAssertTrue(empty.isEmpty)
    }

    /// Station 509 Cornellà Centre (live capture): trains 522 and 523 share
    /// destination "Vall d'Hebron" and both render "2 min", so only the train
    /// identity keeps their `id`s apart for `ForEach`.
    func testArrivalIDsStayUniqueForTrainsInTheSameMinute() throws {
        let data = try Fixtures.data("imetro-L5-509")
        let arrivals = try MetroParser.arrivals(from: data, lineCode: "5")
        let station = try XCTUnwrap(arrivals[509])
        XCTAssertEqual(station.count, 3)

        let sameMinute = station.filter { $0.rawText == "2 min" }
        XCTAssertEqual(sameMinute.count, 2)
        XCTAssertEqual(Set(sameMinute.map(\.destination)), ["Vall d'Hebron"])
        XCTAssertEqual(Set(sameMinute.compactMap(\.serviceCode)), ["522", "523"])
        XCTAssertEqual(Set(sameMinute.map(\.id)).count, 2)
        XCTAssertEqual(Set(station.map(\.id)).count, station.count)

        // An arrival without a service code keeps a stable, non-empty id.
        let anonymous = Arrival(stationCode: 509, lineCode: "5", destination: "Vall d'Hebron", seconds: 139, rawText: "2 min")
        XCTAssertNil(anonymous.serviceCode)
        XCTAssertFalse(anonymous.id.isEmpty)
    }

    /// L9N, L9S, L10N, L10S and FM report no trains at all: parsing must return
    /// an empty result, not throw and not fabricate entries, so the UI can say
    /// "sense dades en temps real" instead of looking stuck loading.
    func testLinesWithoutRealTimeDataDecodeToNoArrivals() throws {
        // FM answers with `estacions: []`.
        let fm = try MetroParser.arrivals(from: try Fixtures.data("imetro-FM"), lineCode: "99")
        XCTAssertTrue(fm.isEmpty)

        // L9N answers with the shared L9N/L10N stations and empty `propers_trens`.
        let l9nData = try Fixtures.data("imetro-L9N")
        XCTAssertTrue(try MetroParser.arrivals(from: l9nData, lineCode: "94").isEmpty)
        XCTAssertTrue(try MetroParser.arrivals(from: l9nData, lineCode: "104").isEmpty)
    }

    /// One formatter for every screen: integer division used to print "0 min"
    /// for the sub-minute arrivals the live feed really returns.
    func testCountdownTextKeepsSubMinuteArrivalsReadable() {
        XCTAssertEqual(Arrival.countdownText(seconds: 0), "<1 min")
        XCTAssertEqual(Arrival.countdownText(seconds: 1), "<1 min")
        XCTAssertEqual(Arrival.countdownText(seconds: 59), "<1 min")
        XCTAssertEqual(Arrival.countdownText(seconds: 60), "1 min")
        XCTAssertEqual(Arrival.countdownText(seconds: 119), "1 min")
        XCTAssertEqual(Arrival.countdownText(seconds: 120), "2 min")
    }

    func testAlertsDecodeLivePayload() throws {
        let data = try Fixtures.data("alerts")
        let alerts = try AlertParser.alerts(from: data)
        XCTAssertEqual(alerts.count, 2)

        // Live `id` is an Int (228295); the parser normalizes it to a string.
        XCTAssertEqual(alerts[0].id, "228295")
        XCTAssertEqual(Set(alerts[0].lineCodes), ["2"])
        XCTAssertEqual(alerts[0].stationNames, ["La Pau", "Verneda", "Artigues | Sant Adrià", "Sant Roc", "Gorg"])
        let begin = try XCTUnwrap(alerts[0].beginDate)
        let end = try XCTUnwrap(alerts[0].endDate)
        XCTAssertEqual(begin.timeIntervalSince1970, 1793272800.0, accuracy: 0.001)
        XCTAssertEqual(end.timeIntervalSince1970, 1796351400.0, accuracy: 0.001)
        // The disruption text lives in `publications[0].textCa`, not in a
        // top-level `description`, `text_ca` or `text` key.
        XCTAssertEqual(
            alerts[0].text,
            "Per treballs en la infraestructura, del 2 de novembre al 3 de desembre, sense servei a l'L2 entre La Pau i Gorg."
        )

        // Second alert covers two lines and its entities omit the
        // direction/entrance fields.
        XCTAssertEqual(alerts[1].id, "224755")
        XCTAssertEqual(alerts[1].lineCodes, ["1", "5"])
        XCTAssertEqual(alerts[1].stationNames, ["Plaça de Sants"])
        XCTAssertEqual(alerts[1].text?.hasPrefix("Fins al 27/03/2027"), true)
    }

    func testAlertTextFallsBackToOtherLanguagesThenLegacyKeys() throws {
        let json = """
        {"data":{"alerts":[
          {"id":1,"publications":[{"textEs":"Aviso en castellano","textEn":"English notice"}]},
          {"id":2,"publications":[{"headerCa":"Cap text"}],"description":"Text antic"},
          {"id":3,"publications":[{"textEn":"English only"}]}
        ]}}
        """.data(using: .utf8)!
        let alerts = try AlertParser.alerts(from: json)
        XCTAssertEqual(alerts.map(\.text), ["Aviso en castellano", "Text antic", "English only"])
    }

    func testMalformedPayloadsThrow() {
        XCTAssertThrowsError(try GeoJSONParser.stations(from: Data("{}".utf8), lineCode: "1"))
        XCTAssertThrowsError(try GeoJSONParser.geometry(from: Data("{}".utf8)))
        XCTAssertThrowsError(try MetroParser.arrivals(from: Data("{}".utf8), lineCode: "1"))
        XCTAssertThrowsError(try AlertParser.alerts(from: Data("{}".utf8)))
    }

    /// TMB paths only accept the numeric `CODI_LINIA`: "9N" or "FM" return 404.
    func testLineCodesAreNumericTMBCodes() {
        XCTAssertTrue(MetroLine.allLines.allSatisfy { Int($0.code) != nil })
        XCTAssertEqual(MetroLine.line(forCode: "94")?.displayName, "L9N")
        XCTAssertEqual(MetroLine.line(forCode: "99")?.displayName, "FM")
    }

    /// Every line has a colour in the network data: these are the live
    /// `COLOR_LINIA` / `color_linia` values, not display approximations.
    func testLineColorsMatchLiveNetworkData() {
        let expected = [
            "1": "CE1126", "2": "93248F", "3": "1EB53A", "4": "F7A30E", "5": "005A97",
            "94": "FB712B", "91": "FB712B", "104": "00A6D6", "101": "00A6D6",
            "11": "89B94C", "99": "004C38",
        ]
        XCTAssertEqual(MetroLine.allLines.count, expected.count)
        for line in MetroLine.allLines {
            XCTAssertEqual(line.colorHex, expected[line.code], "wrong colour for \(line.displayName)")
        }
    }
}
