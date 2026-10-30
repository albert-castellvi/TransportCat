import XCTest
@testable import TransportCat

/// Replays a captured live L1 poll through parser and engine (S6): the S1
/// identity (one position per `codi_servei` + `codi_trajecte`) and the S2
/// direction (`codi_via`) are checked against an independent statement of the
/// rules, written here from the arrival data only.
final class TrainReplayTests: XCTestCase {
    /// The captured poll, flattened to one arrival list like the app builds
    /// from `arrivalsByStop`.
    private func capturedArrivals() throws -> [Arrival] {
        let byStop = try MetroParser.arrivals(from: try Fixtures.data("imetro-L1"), lineCode: "1")
        return byStop.keys.sorted().flatMap { byStop[$0] ?? [] }
    }

    /// Reference implementation of the collapse + direction rules (S1, S2),
    /// computed from the arrivals alone. Returns the expected train ids mapped
    /// to their direction.
    private func expectedTrains(arrivals: [Arrival], stations: [Station]) -> [String: Bool] {
        var best: [String: (seconds: Int, forward: Bool)] = [:]
        for arrival in arrivals {
            guard let seconds = arrival.seconds,
                  let stationIndex = stations.firstIndex(where: { $0.code == arrival.stationCode }) else {
                continue
            }
            let forward: Bool
            if let via = arrival.via {
                forward = via == 1
            } else if arrival.destination.caseInsensitiveCompare(stations[stations.count - 1].name) == .orderedSame {
                forward = true
            } else if arrival.destination.caseInsensitiveCompare(stations[0].name) == .orderedSame {
                forward = false
            } else {
                forward = true
            }
            // A train that would approach a station with no previous station
            // along its direction has no segment to be drawn on.
            let previousIndex = forward ? stationIndex - 1 : stationIndex + 1
            guard stations.indices.contains(previousIndex) else { continue }

            let id: String
            if let serviceCode = arrival.serviceCode {
                id = "1-\(serviceCode)-\(arrival.trajectCode ?? "")"
            } else {
                id = "1-\(arrival.destination)-\(arrival.stationCode)-\(seconds)"
            }
            if let current = best[id], current.seconds <= seconds { continue }
            best[id] = (seconds: seconds, forward: forward)
        }
        return best.mapValues { $0.forward }
    }

    /// Parser surface the engine relies on: the live capture carries both the
    /// via and the route code, and via 1 is the run toward the line's last
    /// station (Fondo) while via 2 is the run toward the first one (Hospital
    /// de Bellvitge).
    func testCaptureCarriesViaAndRouteCode() throws {
        let arrivals = try capturedArrivals()
        XCTAssertFalse(arrivals.isEmpty)
        XCTAssertTrue(arrivals.allSatisfy { $0.serviceCode != nil })
        XCTAssertTrue(arrivals.allSatisfy { $0.via != nil })
        XCTAssertTrue(arrivals.allSatisfy { $0.trajectCode != nil })
        XCTAssertEqual(Set(arrivals.compactMap(\.via)), [1, 2])
        XCTAssertEqual(Set(arrivals.compactMap(\.trajectCode)), ["0011", "0012"])

        for arrival in arrivals {
            switch arrival.via {
            case .some(1):
                XCTAssertEqual(arrival.destination, "Fondo")
                XCTAssertEqual(arrival.trajectCode, "0011")
            case .some(2):
                XCTAssertEqual(arrival.destination, "Hospital de Bellvitge")
                XCTAssertEqual(arrival.trajectCode, "0012")
            default:
                XCTFail("unexpected via \(String(describing: arrival.via))")
            }
        }
    }

    /// The committed fixtures do not overlap: the stations fixture holds the
    /// three Bellvitge stations while the capture polls La Sagrera (133) and
    /// Baró de Viver (138). Nothing in it can be drawn, and the assertion is
    /// computed from the fixture, so it stays exact instead of flaky.
    func testFixtureSubsetCannotDrawTheCapturedTrains() throws {
        let stations = try GeoJSONParser.stations(from: try Fixtures.data("stations-L1"), lineCode: "1")
        let geometry = try GeoJSONParser.geometry(from: try Fixtures.data("metro-line-L1"))
        let engine = try XCTUnwrap(TrainPositionEngine.make(stations: stations, geometry: geometry))

        let arrivals = try capturedArrivals()
        let expected = expectedTrains(arrivals: arrivals, stations: stations)
        let positions = engine.positions(lineCode: "1", arrivals: arrivals)

        XCTAssertTrue(expected.isEmpty)
        XCTAssertTrue(positions.isEmpty)
    }

    /// S1/S2 on the captured poll, with a line that reaches both polled
    /// stations. The geometry fixture does not cover La Sagrera, so the route
    /// is the straight synthetic one used by the engine tests.
    func testReplayCollapsesTrainsAndTakesDirectionFromVia() throws {
        let stations = [
            Station(code: 133, name: "La Sagrera", orderInLine: 1, lineCode: "1", latitude: 41.42236877, longitude: 2.18400000, id: nil, accessible: nil),
            Station(code: 138, name: "Baró de Viver", orderInLine: 2, lineCode: "1", latitude: 41.44500000, longitude: 2.18400000, id: nil, accessible: nil),
        ]
        let geometry = LineGeometry(points: [
            GeoPoint(latitude: 41.41000000, longitude: 2.18400000),
            GeoPoint(latitude: 41.45000000, longitude: 2.18400000),
        ])
        let engine = try XCTUnwrap(TrainPositionEngine.make(stations: stations, geometry: geometry))
        let arrivals = try capturedArrivals()

        let expected = expectedTrains(arrivals: arrivals, stations: stations)
        let positions = engine.positions(lineCode: "1", arrivals: arrivals)

        // Five (service, route code) pairs in the capture; the two via 1
        // arrivals at station 133 are dropped because nothing precedes the
        // first station in that direction.
        XCTAssertEqual(expected.count, 3)
        XCTAssertEqual(positions.count, expected.count)
        XCTAssertEqual(positions.map(\.id), expected.keys.sorted())
        XCTAssertEqual(Set(positions.map(\.id)).count, positions.count)

        for position in positions {
            let expectedForward = try XCTUnwrap(expected[position.id], "no expected train \(position.id)")
            XCTAssertEqual(position.forward, expectedForward)
            // The via 1 trains approach Baró de Viver, the via 2 one La Sagrera.
            XCTAssertEqual(position.nextStationCode, position.forward ? 138 : 133)
        }
    }
}
