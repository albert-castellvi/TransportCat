import XCTest
@testable import TransportCat

/// Decoding tests for the trip-level ETA of Renfe's `trip_updates.json`.
///
/// The payloads are synthetic but shaped like the real feed: every timestamp is
/// a string, a trip may carry several stop updates and the first usable one is
/// the next stop. The cases come from the review's real trains (25661 R1 to
/// Badalona, 77550 R4 to Sant Joan Despí) so the assertions pin the joins the
/// map depends on.
final class RodaliesTripETATests: XCTestCase {
    private let knownLines = ["R1", "R4", "R16"]
    /// 2026-11-18 17:12:22 UTC, the base of the review's vehicle samples.
    private let base = Date(timeIntervalSince1970: 1_795_021_942)

    // MARK: - Fixtures

    private func feed(_ updates: [[String: Any]]) throws -> Data {
        let payload: [String: Any] = [
            "header": ["gtfsRealtimeVersion": "2.0", "timestamp": "1795021942"],
            "entity": updates,
        ]
        return try JSONSerialization.data(withJSONObject: payload)
    }

    private func tripUpdate(_ tripID: String, stops: [[String: Any]]) -> [String: Any] {
        ["tripUpdate": ["trip": ["tripId": tripID], "stopTimeUpdate": stops]]
    }

    private func stop(
        _ stopID: String?,
        arrival: TimeInterval? = nil,
        departure: TimeInterval? = nil
    ) -> [String: Any] {
        var entry: [String: Any] = [:]
        if let stopID { entry["stopId"] = stopID }
        if let arrival { entry["arrival"] = ["time": String(Int(arrival))] }
        if let departure { entry["departure"] = ["time": String(Int(departure))] }
        return entry
    }

    // MARK: - Next stop and predicted arrival

    /// 25661 R1 has just left Sant Adrià de Besòs (79403); the trip update
    /// points at Badalona (79404) with its arrival epoch.
    func testTheNextStopAndPredictedArrivalAreRead() throws {
        let data = try feed([
            tripUpdate("5121X25661R1", stops: [stop("79404", arrival: base.timeIntervalSince1970 + 480)]),
        ])

        let etas = RodaliesParser.tripETAs(from: data, knownLines: knownLines)
        let eta = try XCTUnwrap(etas["5121X25661R1"])

        XCTAssertEqual(etas.count, 1)
        XCTAssertEqual(eta.tripID, "5121X25661R1")
        XCTAssertEqual(eta.nextStopID, "79404")
        XCTAssertEqual(eta.predictedArrival, base.addingTimeInterval(480))
    }

    /// 77550 R4 is heading to Sant Joan Despí (72302) after Cornellà (72303).
    func testR4TripFromCornellaToSantJoanDespiIsParsed() throws {
        let data = try feed([
            tripUpdate("5121X77550R4", stops: [stop("72302", arrival: base.timeIntervalSince1970 + 540)]),
        ])

        let eta = try XCTUnwrap(RodaliesParser.tripETAs(from: data, knownLines: knownLines)["5121X77550R4"])

        XCTAssertEqual(eta.nextStopID, "72302")
        XCTAssertEqual(eta.predictedArrival, base.addingTimeInterval(540))
    }

    /// Some trips publish only `departure.time`; it is the same prediction for
    /// the stop and is used instead of dropping the trip.
    func testDepartureTimeIsTheFallbackWhenArrivalIsMissing() throws {
        let data = try feed([
            tripUpdate("5121X77550R4", stops: [stop("72302", departure: base.timeIntervalSince1970 + 540)]),
        ])

        let eta = try XCTUnwrap(RodaliesParser.tripETAs(from: data, knownLines: knownLines)["5121X77550R4"])

        XCTAssertEqual(eta.predictedArrival, base.addingTimeInterval(540))
    }

    /// Renfe may list skipped or malformed entries before the next stop: the
    /// first stop update that carries both a stop id and a time wins, and the
    /// later ones are not misread as the next stop.
    func testTheFirstUsableStopUpdateWins() throws {
        let data = try feed([
            tripUpdate("5121X25661R1", stops: [
                stop("79403"), // no time: a skipped or incomplete entry
                stop("79404", arrival: base.timeIntervalSince1970 + 480),
                stop("79405", arrival: base.timeIntervalSince1970 + 900),
            ]),
        ])

        let eta = try XCTUnwrap(RodaliesParser.tripETAs(from: data, knownLines: knownLines)["5121X25661R1"])

        XCTAssertEqual(eta.nextStopID, "79404")
        XCTAssertEqual(eta.predictedArrival, base.addingTimeInterval(480))
    }

    /// Numeric epochs are accepted as well as the strings the live feed sends.
    func testNumericEpochsAreAccepted() throws {
        let data = try feed([
            tripUpdate("5121X25661R1", stops: [["stopId": "79404", "arrival": ["time": 1_795_022_422]]]),
        ])

        let eta = try XCTUnwrap(RodaliesParser.tripETAs(from: data, knownLines: knownLines)["5121X25661R1"])

        XCTAssertEqual(eta.predictedArrival, Date(timeIntervalSince1970: 1_795_022_422))
    }

    // MARK: - Filtering and tolerance

    /// Only nucleus trips of known lines are read: another network and a line
    /// outside the bundled topology are skipped, each on its own.
    func testTripsOutsideTheNucleusAndUnknownLinesAreSkipped() throws {
        let data = try feed([
            tripUpdate("3016V35713C5", stops: [stop("1", arrival: base.timeIntervalSince1970 + 60)]),
            tripUpdate("5121X99999R99", stops: [stop("2", arrival: base.timeIntervalSince1970 + 60)]),
            tripUpdate("5121X25661R1", stops: [stop("79404", arrival: base.timeIntervalSince1970 + 480)]),
        ])

        let etas = RodaliesParser.tripETAs(from: data, knownLines: knownLines)

        XCTAssertEqual(Set(etas.keys), ["5121X25661R1"])
    }

    /// A trip with no usable stop update is absent, which keeps "no prediction"
    /// different from "predicted on time".
    func testTripUpdatesWithoutStopIdOrTimeAreIgnored() throws {
        let data = try feed([
            tripUpdate("5121X25661R1", stops: [stop(nil, arrival: base.timeIntervalSince1970 + 60)]),
            tripUpdate("5121X77550R4", stops: [stop("72302")]),
        ])

        XCTAssertTrue(RodaliesParser.tripETAs(from: data, knownLines: knownLines).isEmpty)
    }

    /// An ETA eight minutes in the past and one ninety minutes ahead are valid
    /// payloads: the parser keeps them and the progress layer judges them
    /// against a clock (it is the only layer that has one).
    func testOutOfWindowPredictionsAreKeptForTheProgressLayer() throws {
        let data = try feed([
            tripUpdate("5121X25661R1", stops: [stop("79404", arrival: base.timeIntervalSince1970 - 480)]),
            tripUpdate("5121X77550R4", stops: [stop("72302", arrival: base.timeIntervalSince1970 + 5_400)]),
        ])

        let etas = RodaliesParser.tripETAs(from: data, knownLines: knownLines)

        XCTAssertEqual(etas["5121X25661R1"]?.predictedArrival, base.addingTimeInterval(-480))
        XCTAssertEqual(etas["5121X77550R4"]?.predictedArrival, base.addingTimeInterval(5_400))
    }

    /// A payload that is not a GTFS-Realtime envelope is empty, never fatal.
    func testMalformedPayloadIsEmpty() {
        XCTAssertTrue(RodaliesParser.tripETAs(from: Data("not json".utf8), knownLines: knownLines).isEmpty)
        XCTAssertTrue(RodaliesParser.tripETAs(from: Data("{\"entity\":[]}".utf8), knownLines: knownLines).isEmpty)
    }
}
