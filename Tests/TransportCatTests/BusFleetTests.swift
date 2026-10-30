import XCTest
@testable import TransportCat

/// Tests for the bus fleet (specs S4, S5): which stops a poll asks about, how
/// a direction is assembled from the real H12 fixtures, and where the buses
/// land once the recorded iBus snapshot is replayed through the engine.
///
/// Fixtures: `bus-stops-212` (68 stops, 34 per direction), `bus-recs-212`
/// (four route variants) and `ibus-H12-snapshot` (the per-stop real-time feed
/// for all 66 distinct stop codes, captured at one moment).
final class BusFleetTests: XCTestCase {
    // MARK: - Fixtures

    private func allStops() throws -> [BusStop] {
        try BusParser.stops(from: Fixtures.data("bus-stops-212"))
    }

    /// Stops of one direction, in `ORDRE` order: `pollPlan` is documented to
    /// receive them sorted, and the endpoint returns the whole list unordered.
    private func stopsSorted(directionID: Int) throws -> [BusStop] {
        try allStops()
            .filter { $0.directionID == directionID }
            .sorted { $0.order < $1.order }
    }

    private func allRoutes() throws -> [BusRoute] {
        try BusParser.routes(from: Fixtures.data("bus-recs-212"))
    }

    /// The recorded iBus feed, replayed as `BusArrival` values: one per bus
    /// entry of the snapshot, with the countdown measured against the
    /// `timestamp` of its own stop response.
    private func snapshotArrivals() throws -> [BusArrival] {
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try Fixtures.data("ibus-H12-snapshot")) as? [String: Any]
        )
        let stops = try XCTUnwrap(root["stops"] as? [String: Any])
        var arrivals: [BusArrival] = []
        for (key, value) in stops {
            let stopCode = try XCTUnwrap(Int(key))
            let stop = try XCTUnwrap(value as? [String: Any])
            let timestamp = try XCTUnwrap((stop["timestamp"] as? NSNumber)?.doubleValue)
            let lines = try XCTUnwrap(stop["linies_trajectes"] as? [[String: Any]])
            for line in lines {
                let lineCode = try XCTUnwrap((line["codi_linia"] as? NSNumber)?.intValue)
                let lineName = try XCTUnwrap(line["nom_linia"] as? String)
                let directionID = try XCTUnwrap((line["id_sentit"] as? NSNumber)?.intValue)
                let trajectCode = try XCTUnwrap(line["codi_trajecte"] as? String)
                let destination = try XCTUnwrap(line["desti_trajecte"] as? String)
                let buses = try XCTUnwrap(line["propers_busos"] as? [[String: Any]])
                for bus in buses {
                    let arrivalAt = try XCTUnwrap((bus["temps_arribada"] as? NSNumber)?.doubleValue)
                    let seconds = max(0, Int(((arrivalAt - timestamp) / 1_000).rounded(.down)))
                    arrivals.append(BusArrival(
                        stopCode: stopCode,
                        lineCode: lineCode,
                        lineName: lineName,
                        directionID: directionID,
                        trajectCode: trajectCode,
                        destination: destination,
                        seconds: seconds,
                        busID: (bus["id_bus"] as? NSNumber)?.intValue,
                        rampStatus: nil
                    ))
                }
            }
        }
        return arrivals.sorted { $0.id < $1.id }
    }

    private func h12Directions(maxRequests: Int) throws -> [BusDirection] {
        BusFleet.directions(
            stops: try allStops(),
            routes: try allRoutes(),
            lineCode: "212",
            maxRequests: maxRequests
        )
    }

    // MARK: - Synthetic values

    private func makeStop(
        code: Int,
        order: Int,
        directionID: Int = 1,
        routeID: Int = 1,
        latitude: Double = 41
    ) -> BusStop {
        BusStop(
            code: code,
            name: "Parada \(code)",
            address: "Carrer \(code)",
            order: order,
            directionID: directionID,
            directionName: directionID == 1 ? "Anada" : "Tornada",
            destinationName: directionID == 1 ? "Besòs Verneda" : "Gornal",
            distanceFromPrevious: 300,
            latitude: latitude,
            longitude: 2,
            routeID: routeID
        )
    }

    /// A straight north-south polyline through stops whose latitude is
    /// `41 + index * 0.001`, so a synthetic direction is always projectable.
    private func makePolyline(points count: Int, startLatitude: Double = 41) -> LineGeometry {
        LineGeometry(points: (0..<count).map {
            GeoPoint(latitude: startLatitude + Double($0) * 0.001, longitude: 2)
        })
    }

    // MARK: - Poll plan (S5)

    func testPollPlanReturnsEveryStopWhenTheyFit() throws {
        let stops = try stopsSorted(directionID: 1)
        XCTAssertEqual(stops.count, 34)
        XCTAssertEqual(BusFleet.pollPlan(stops: stops, maxRequests: 34).map(\.id), stops.map(\.id))
        XCTAssertEqual(BusFleet.pollPlan(stops: stops, maxRequests: 200).map(\.id), stops.map(\.id))
    }

    func testPollPlanKeepsBothEndsAndSpacesTheRestEvenly() throws {
        let stops = try stopsSorted(directionID: 1)
        let plan = BusFleet.pollPlan(stops: stops, maxRequests: 15)
        XCTAssertEqual(plan.count, 15)
        XCTAssertEqual(plan.first?.id, stops.first?.id)
        XCTAssertEqual(plan.last?.id, stops.last?.id)
        // No repeats and strictly increasing `order`: the poll order and the
        // request count are both deterministic.
        XCTAssertEqual(Set(plan.map(\.id)).count, plan.count)
        let orders = plan.map(\.order)
        XCTAssertEqual(orders, orders.sorted())
        XCTAssertEqual(Set(orders).count, orders.count)
        // Evenly spaced as whole indices allow: the gap between consecutive
        // stops of the plan never differs by more than one stop.
        let indices = plan.compactMap { planned in stops.firstIndex { $0.id == planned.id } }
        let gaps = zip(indices.dropFirst(), indices).map { $0 - $1 }
        XCTAssertFalse(gaps.isEmpty)
        XCTAssertEqual((gaps.max() ?? 0) - (gaps.min() ?? 0), 1)
        // Deterministic: the same input always yields the same plan.
        XCTAssertEqual(BusFleet.pollPlan(stops: stops, maxRequests: 15).map(\.id), plan.map(\.id))
    }

    func testPollPlanEdgeCases() {
        XCTAssertTrue(BusFleet.pollPlan(stops: [], maxRequests: 10).isEmpty)

        let one = [makeStop(code: 1, order: 1)]
        XCTAssertEqual(BusFleet.pollPlan(stops: one, maxRequests: 10).map(\.id), one.map(\.id))

        let two = [makeStop(code: 1, order: 1), makeStop(code: 2, order: 2)]
        XCTAssertEqual(BusFleet.pollPlan(stops: two, maxRequests: 10).map(\.code), [1, 2])
        // A budget of one request still keeps both ends: a segment needs two.
        XCTAssertEqual(BusFleet.pollPlan(stops: two, maxRequests: 1).map(\.code), [1, 2])

        let four = (1...4).map { makeStop(code: $0, order: $0) }
        XCTAssertEqual(BusFleet.pollPlan(stops: four, maxRequests: 2).map(\.code), [1, 4])
        XCTAssertEqual(BusFleet.pollPlan(stops: four, maxRequests: 3).map(\.code), [1, 3, 4])
    }

    // MARK: - Directions (S4)

    func testDirectionsAssembleBothDirectionsOfH12() throws {
        let stops = try allStops()
        let routes = try allRoutes()
        let directions = try h12Directions(maxRequests: 30)

        XCTAssertEqual(directions.map(\.id), [1, 2])
        var totalPolled = 0
        for direction in directions {
            let ownStops = stops.filter { $0.directionID == direction.id }
            XCTAssertEqual(ownStops.count, 34)
            XCTAssertEqual(direction.stops.count, 34)
            XCTAssertEqual(direction.stops.map(\.order), (1...34).map { $0 })
            XCTAssertEqual(direction.name, ownStops[0].directionName)
            XCTAssertEqual(direction.destinationName, ownStops[0].destinationName)

            // The route whose ID_RECORREGUT matches the stops', not just the
            // most detailed variant of the direction.
            let routeID = ownStops[0].routeID
            XCTAssertEqual(Set(ownStops.map(\.routeID)), [routeID])
            let expected = try XCTUnwrap(routes.first { $0.routeID == routeID })
            XCTAssertEqual(direction.route, expected.geometry)

            XCTAssertGreaterThanOrEqual(direction.polledStops.count, 2)
            XCTAssertLessThanOrEqual(direction.polledStops.count, 15)
            XCTAssertEqual(direction.polledStops.first?.id, direction.stops.first?.id)
            XCTAssertEqual(direction.polledStops.last?.id, direction.stops.last?.id)
            XCTAssertEqual(direction.engine.speed, BusFleet.defaultSpeed)
            totalPolled += direction.polledStops.count
        }
        // The whole poll stays inside the budget of spec S5.
        XCTAssertLessThanOrEqual(totalPolled, 30)
    }

    func testDirectionsFallBackToTheMostDetailedRouteOfTheDirection() throws {
        let stops = (1...4).map { makeStop(code: $0, order: $0, routeID: 999) }
        let coarse = BusRoute(routeID: 11, directionID: 1, geometry: makePolyline(points: 2))
        let detailed = BusRoute(routeID: 12, directionID: 1, geometry: makePolyline(points: 9))
        let otherDirection = BusRoute(routeID: 13, directionID: 2, geometry: makePolyline(points: 40))

        let directions = BusFleet.directions(
            stops: stops,
            routes: [coarse, detailed, otherDirection],
            lineCode: "212",
            maxRequests: 30
        )
        XCTAssertEqual(directions.map(\.id), [1])
        XCTAssertEqual(directions.first?.route, detailed.geometry)
    }

    func testDirectionsSkipADirectionThatCannotBeBuilt() {
        let stops = (1...4).map { makeStop(code: $0, order: $0, routeID: 7) }
        XCTAssertTrue(BusFleet.directions(stops: stops, routes: [], lineCode: "212", maxRequests: 30).isEmpty)
        XCTAssertTrue(BusFleet.directions(stops: Array(stops.prefix(1)), routes: [
            BusRoute(routeID: 7, directionID: 1, geometry: makePolyline(points: 4)),
        ], lineCode: "212", maxRequests: 30).isEmpty)
    }

    // MARK: - Positions (S4)

    func testPositionsPlaceOneBusPerPhysicalBus() throws {
        let arrivals = try snapshotArrivals()
        XCTAssertFalse(arrivals.contains { $0.busID == nil })
        let directions = try h12Directions(maxRequests: 30)

        var expectedTotal = 0
        for direction in directions {
            let polledCodes = Set(direction.polledStops.map(\.code))
            let firstPolled = direction.polledStops.first?.code
            // The engine keeps the soonest arrival of each bus, and a bus whose
            // soonest polled stop is the first one has no previous stop to
            // travel from (`via = 1` always moves toward the last stop): it is
            // not placed. Deriving the count that way is what the expectation
            // asserts, instead of a literal from the fixture.
            var soonest: [String: (seconds: Int, stopCode: Int)] = [:]
            for arrival in arrivals where arrival.directionID == direction.id && polledCodes.contains(arrival.stopCode) {
                guard let busID = arrival.busID else { continue }
                let key = "\(busID)-\(arrival.trajectCode)"
                if let current = soonest[key], current.seconds <= arrival.seconds { continue }
                soonest[key] = (arrival.seconds, arrival.stopCode)
            }
            let expected = soonest.values.filter { $0.stopCode != firstPolled }.count
            let positions = BusFleet.positions(direction: direction, arrivals: arrivals, lineCode: "212")

            XCTAssertEqual(positions.count, expected)
            expectedTotal += expected
            XCTAssertEqual(Set(positions.map(\.id)).count, positions.count)
            XCTAssertTrue(positions.allSatisfy { $0.directionID == direction.id })
            XCTAssertTrue(positions.allSatisfy { $0.id.hasPrefix("\(direction.id)-") })
            XCTAssertTrue(positions.allSatisfy { $0.train.lineCode == "212" })

            let cumulative = GeoMath.cumulativeDistances(of: direction.route.points)
            for position in positions {
                let projection = try XCTUnwrap(GeoMath.nearestProjection(
                    of: position.train.position,
                    in: direction.route.points,
                    cumulative: cumulative
                ))
                XCTAssertLessThanOrEqual(projection.offsetMeters, 40)
                XCTAssertEqual(position.train.forward, true)
            }
        }
        // Not a literal: the count of buses the snapshot can place.
        XCTAssertGreaterThan(expectedTotal, 0)
        XCTAssertEqual(directions.flatMap { BusFleet.positions(direction: $0, arrivals: arrivals, lineCode: "212") }.count, expectedTotal)
    }

    func testPositionsIgnoreArrivalsWithoutBusIdentity() throws {
        let directions = try h12Directions(maxRequests: 30)
        let direction = try XCTUnwrap(directions.first)
        let polled = direction.polledStops
        let stop = polled[1]
        let arrival = BusArrival(
            stopCode: stop.code,
            lineCode: 212,
            lineName: "H12",
            directionID: direction.id,
            trajectCode: "2120",
            destination: direction.destinationName,
            seconds: 300,
            busID: nil,
            rampStatus: nil
        )
        XCTAssertTrue(BusFleet.positions(direction: direction, arrivals: [arrival], lineCode: "212").isEmpty)
        // An arrival without identity cannot hide the ones that do have it.
        let withIdentity = BusArrival(
            stopCode: stop.code,
            lineCode: 212,
            lineName: "H12",
            directionID: direction.id,
            trajectCode: "2120",
            destination: direction.destinationName,
            seconds: 300,
            busID: 4242,
            rampStatus: nil
        )
        let positions = BusFleet.positions(direction: direction, arrivals: [arrival, withIdentity], lineCode: "212")
        XCTAssertEqual(positions.count, 1)
        XCTAssertEqual(positions.first?.directionID, direction.id)
    }

    // MARK: - Diagram index (S8)

    func testStopIndexPositionIsMonotoneAndClamped() throws {
        let directions = try h12Directions(maxRequests: 30)
        for direction in directions {
            let cumulative = GeoMath.cumulativeDistances(of: direction.route.points)
            let total = try XCTUnwrap(cumulative.last)
            let lastIndex = Double(direction.stops.count - 1)
            let stopDistances = try direction.stops.map { stop -> Double in
                try XCTUnwrap(GeoMath.nearestProjection(
                    of: GeoPoint(latitude: stop.latitude, longitude: stop.longitude),
                    in: direction.route.points,
                    cumulative: cumulative
                )).distance
            }

            XCTAssertEqual(direction.stopIndexPosition(atRouteDistance: stopDistances.first!), 0, accuracy: 1e-9)
            XCTAssertEqual(direction.stopIndexPosition(atRouteDistance: stopDistances.last!), lastIndex, accuracy: 1e-9)
            // Outside the route there is nothing to interpolate.
            XCTAssertEqual(direction.stopIndexPosition(atRouteDistance: -5_000), 0)
            XCTAssertEqual(direction.stopIndexPosition(atRouteDistance: total + 5_000), lastIndex)

            var previous = -Double.infinity
            for step in 0...200 {
                let distance = total * Double(step) / 200
                let index = direction.stopIndexPosition(atRouteDistance: distance)
                XCTAssertGreaterThanOrEqual(index, previous)
                XCTAssertGreaterThanOrEqual(index, 0)
                XCTAssertLessThanOrEqual(index, lastIndex)
                previous = index
            }
        }
    }

    func testStopIndexPositionInterpolatesBetweenTwoStops() {
        // Four synthetic stops 3 points of latitude apart, on a straight line.
        let stops = (1...4).map { makeStop(code: $0, order: $0, latitude: 41 + Double($0 - 1) * 0.003) }
        let route = makePolyline(points: 7)
        let directions = BusFleet.directions(stops: stops, routes: [
            BusRoute(routeID: 1, directionID: 1, geometry: route),
        ], lineCode: "212", maxRequests: 30)
        let direction = directions[0]
        let cumulative = GeoMath.cumulativeDistances(of: route.points)
        let first = GeoMath.nearestProjection(
            of: GeoPoint(latitude: stops[0].latitude, longitude: 2),
            in: route.points,
            cumulative: cumulative
        )!.distance
        let second = GeoMath.nearestProjection(
            of: GeoPoint(latitude: stops[1].latitude, longitude: 2),
            in: route.points,
            cumulative: cumulative
        )!.distance

        XCTAssertEqual(direction.stopIndexPosition(atRouteDistance: first), 0, accuracy: 1e-9)
        XCTAssertEqual(direction.stopIndexPosition(atRouteDistance: second), 1, accuracy: 1e-9)
        XCTAssertEqual(
            direction.stopIndexPosition(atRouteDistance: (first + second) / 2),
            0.5,
            accuracy: 1e-9
        )
    }

    // MARK: - Sampling error (S5)

    /// The polled subset is a sampling of the line: the same bus placed from
    /// 15 of 34 stops per direction must stay close to the placement from all
    /// of them. 250 m is about one city block and a half, the visual tolerance
    /// of the map at the zoom levels it uses.
    func testPollSubsetKeepsBusesCloseToTheFullPoll() throws {
        let stops = try allStops()
        let routes = try allRoutes()
        let arrivals = try snapshotArrivals()
        let sampled = BusFleet.directions(stops: stops, routes: routes, lineCode: "212", maxRequests: 30)
        let full = BusFleet.directions(stops: stops, routes: routes, lineCode: "212", maxRequests: 200)

        XCTAssertEqual(sampled.map { $0.polledStops.count }, [15, 15])
        XCTAssertEqual(full.map { $0.polledStops.count }, [34, 34])

        var sampledByID: [String: TrainPosition] = [:]
        for direction in sampled {
            for position in BusFleet.positions(direction: direction, arrivals: arrivals, lineCode: "212") {
                sampledByID["\(direction.id)-\(position.train.id)"] = position.train
            }
        }
        var fullByID: [String: TrainPosition] = [:]
        for direction in full {
            for position in BusFleet.positions(direction: direction, arrivals: arrivals, lineCode: "212") {
                fullByID["\(direction.id)-\(position.train.id)"] = position.train
            }
        }

        let shared = Set(sampledByID.keys).intersection(fullByID.keys)
        XCTAssertGreaterThan(shared.count, 0)
        let errors = shared.map { id in
            GeoMath.distanceMeters(from: sampledByID[id]!.position, to: fullByID[id]!.position)
        }
        // Measured on the recorded snapshot: 113.4 m average, 372.2 m worst,
        // over the 13 buses both polls can place.
        let average = errors.reduce(0, +) / Double(errors.count)
        XCTAssertLessThan(average, 250, "average sampling error \(average) m over \(shared.count) buses, worst \(errors.max() ?? 0) m")
    }
}
