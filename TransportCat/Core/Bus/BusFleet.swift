import Foundation

/// One direction of a bus line, ready to place buses on the map (spec S4).
///
/// A direction owns two stop sets and two orderings on purpose:
/// - `polledStops`, the evenly spaced subset iBus is asked about (spec S5),
///   is what `engine` is built on. An engine built on every stop would clamp a
///   bus to the segment next to the only stop that reported it, so the polled
///   subset keeps the segment between two polled stops meaningful.
/// - `stops`, every stop of the direction, is what the Xarxa diagram lists
///   (spec S8). `stopIndexPosition` maps a route distance onto that full row
///   list, so the diagram can draw a bus between two rows the poll never saw.
///
/// `BusFleet.directions` is the only way to build one: the route distances of
/// the full stop list are derived from the geometry once, at construction.
struct BusDirection: Identifiable {
    /// `ID_SENTIT`: 1 = Anada, 2 = Tornada.
    let id: Int
    /// `DESC_SENTIT` ("Anada", "Tornada").
    let name: String
    /// `DESTI_SENTIT`: where this direction ends.
    let destinationName: String
    /// Every stop of the direction, sorted by `order`.
    let stops: [BusStop]
    /// The evenly spaced subset of `stops` the poll asks about.
    let polledStops: [BusStop]
    /// Geometry of this direction: the route whose `ID_RECORREGUT` matches the
    /// stops' one, or the direction's most detailed route when there is none.
    let route: LineGeometry
    /// Position engine over `polledStops`, at the bus speed of `BusFleet`.
    let engine: TrainPositionEngine
    /// Route distance in meters of **every** stop, projected once here so the
    /// diagram never reprojects on a redraw.
    private let stopDistances: [Double]

    init(
        id: Int,
        name: String,
        destinationName: String,
        stops: [BusStop],
        polledStops: [BusStop],
        route: LineGeometry,
        engine: TrainPositionEngine,
        stopDistances: [Double]
    ) {
        self.id = id
        self.name = name
        self.destinationName = destinationName
        self.stops = stops
        self.polledStops = polledStops
        self.route = route
        self.engine = engine
        self.stopDistances = stopDistances
    }

    /// S8: continuous position on the diagram, in stop-row units.
    ///
    /// `0` is the first stop, `1` the second, `1.5` halfway between the second
    /// and the third. Between two consecutive stops the index is interpolated
    /// linearly in their route distances, so the diagram spacing follows the
    /// real road distance instead of a fixed row pitch. The result is clamped
    /// to `0...stops.count-1`: outside the first and last stop there is
    /// nothing to interpolate.
    ///
    /// This mirrors `TrainPositionEngine.stationIndexPosition`, but over every
    /// stop of the direction instead of the polled subset, which is exactly
    /// what the diagram needs. Two stops projected onto the same route
    /// distance (a geometry that doubles back) contribute no interval instead
    /// of dividing by zero, which keeps the result non-decreasing.
    func stopIndexPosition(atRouteDistance distance: Double) -> Double {
        guard let first = stopDistances.first, let last = stopDistances.last else { return 0 }
        let lastIndex = Double(stopDistances.count - 1)
        guard distance.isFinite else { return distance < 0 ? 0 : lastIndex }
        if distance <= first { return 0 }
        if distance >= last { return lastIndex }

        for index in 1..<stopDistances.count {
            let lower = stopDistances[index - 1]
            let upper = stopDistances[index]
            guard upper > lower else { continue }
            if distance <= upper {
                return Double(index - 1) + (distance - lower) / (upper - lower)
            }
        }
        return lastIndex
    }
}

/// A bus on the map: one position of one direction (spec S4).
struct BusPosition: Identifiable {
    /// `<directionID>-<train id>`, so the same bus appearing in both
    /// directions of a line still gets one marker per direction.
    let id: String
    /// `ID_SENTIT` of the direction the bus travels.
    let directionID: Int
    /// Engine output, interpolated by `TrainMotion` between polls.
    let train: TrainPosition
}

/// Builds the per-direction state of a bus line: which stops to poll, the
/// geometry to draw and the buses on it (specs S4, S5).
///
/// Foundation only, no clock and no I/O: every function is a pure function of
/// its arguments, which is what makes the poll plan and the placement
/// testable on Linux against the recorded iBus snapshot.
enum BusFleet {
    /// Average commercial speed of a Barcelona bus, m/s (~16 km/h). Slower
    /// than the metro engine default because a bus shares the road.
    static let defaultSpeed: Double = 4.5

    /// Stops to poll for one direction, evenly spaced (spec S5).
    ///
    /// - Parameters:
    ///   - stops: stops of ONE direction, already sorted by `order`.
    ///   - maxRequests: request budget of that direction.
    /// - Returns: a subset of `stops`, in the same order. It is `stops` itself
    ///   when they already fit, the first and last stop when the budget is 1,
    ///   and otherwise `maxRequests` stops including both ends, spaced as
    ///   evenly as whole indices allow. Empty input returns empty; the result
    ///   never repeats a stop and its indices strictly increase, so the poll
    ///   order is deterministic.
    static func pollPlan(stops: [BusStop], maxRequests: Int) -> [BusStop] {
        guard !stops.isEmpty, maxRequests > 0 else { return [] }
        // Both terminals are needed for a usable segment, so a budget of 1 is
        // raised to 2 rather than losing an end.
        let budget = max(2, maxRequests)
        guard stops.count > budget else { return stops }

        let lastIndex = stops.count - 1
        let steps = budget - 1
        var result: [BusStop] = []
        result.reserveCapacity(budget)
        var previousIndex = -1
        for step in 0...steps {
            // Rounded so the plan is symmetric; the step is greater than 1
            // here (more stops than budget), so the indices cannot collide.
            let index = Int((Double(step) * Double(lastIndex) / Double(steps)).rounded())
            guard index > previousIndex else { continue }
            result.append(stops[index])
            previousIndex = index
        }
        return result
    }

    /// One `BusDirection` per direction of the line, sorted by direction id.
    ///
    /// Each direction takes the route whose `ID_RECORREGUT` matches its stops'
    /// (that is the geometry the stops were measured on); when no route carries
    /// that id it falls back to the direction's most detailed route, and a
    /// direction with no route or no usable segment (fewer than two pollable
    /// stops, or stops that cannot be projected) is skipped instead of
    /// rendering an empty direction.
    ///
    /// - Parameters:
    ///   - stops: every stop of both directions, as the endpoint returns them.
    ///   - routes: every route variant of the line.
    ///   - lineCode: commercial code ("212") stored on the projected stations.
    ///   - maxRequests: request budget of the WHOLE poll; split evenly between
    ///     the directions, rounded up and never below 2.
    static func directions(stops: [BusStop], routes: [BusRoute], lineCode: String, maxRequests: Int) -> [BusDirection] {
        let grouped = Dictionary(grouping: stops, by: \.directionID)
        let directionIDs = grouped.keys.sorted()
        guard !directionIDs.isEmpty else { return [] }

        let perDirectionRequests = max(
            2,
            Int((Double(maxRequests) / Double(directionIDs.count)).rounded(.up))
        )

        var result: [BusDirection] = []
        for directionID in directionIDs {
            let ordered = (grouped[directionID] ?? []).sorted {
                $0.order == $1.order ? $0.code < $1.code : $0.order < $1.order
            }
            guard let first = ordered.first else { continue }
            guard let route = route(for: ordered, directionID: directionID, routes: routes) else { continue }

            let polled = pollPlan(stops: ordered, maxRequests: perDirectionRequests)
            guard polled.count >= 2 else { continue }
            guard let engine = TrainPositionEngine.make(
                stations: polled.map { $0.asStation(lineCode: lineCode) },
                geometry: route.geometry,
                speedMetersPerSecond: defaultSpeed
            ) else { continue }
            guard let stopDistances = self.stopDistances(of: ordered, on: route.geometry) else { continue }

            result.append(BusDirection(
                id: directionID,
                name: first.directionName,
                destinationName: first.destinationName,
                stops: ordered,
                polledStops: polled,
                route: route.geometry,
                engine: engine,
                stopDistances: stopDistances
            ))
        }
        return result
    }

    /// Buses of one direction, from the arrivals of the polled stops.
    ///
    /// Only arrivals the feed can place take part: a non-nil `id_bus` (spec
    /// S4), the direction they belong to, and a polled stop (an arrival at an
    /// unpolled stop has no segment in the engine). They are handed to
    /// `TrainPositionEngine` as metro arrivals with `via = 1`, every bus
    /// moving toward the last stop of its own direction, and the engine
    /// collapses the several arrivals of one bus into its next stop.
    ///
    /// - Parameters:
    ///   - direction: the direction whose engine places the buses.
    ///   - arrivals: arrivals at the polled stops of the line, any direction.
    ///   - lineCode: commercial code stored on the resulting positions.
    static func positions(direction: BusDirection, arrivals: [BusArrival], lineCode: String) -> [BusPosition] {
        let polledCodes = Set(direction.polledStops.map(\.code))
        let relevant = arrivals.filter { arrival in
            guard let busID = arrival.busID, busID != 0 else { return false }
            return arrival.directionID == direction.id && polledCodes.contains(arrival.stopCode)
        }
        let asArrivals = relevant.compactMap { arrival -> Arrival? in
            guard let busID = arrival.busID else { return nil }
            return Arrival(
                stationCode: arrival.stopCode,
                lineCode: lineCode,
                destination: arrival.destination,
                seconds: arrival.seconds,
                rawText: "",
                serviceCode: String(busID),
                trajectCode: arrival.trajectCode,
                via: 1
            )
        }
        return direction.engine.positions(lineCode: lineCode, arrivals: asArrivals).map { train in
            BusPosition(id: "\(direction.id)-\(train.id)", directionID: direction.id, train: train)
        }
    }

    // MARK: - Route selection

    /// The geometry a direction draws: the route whose `ID_RECORREGUT` matches
    /// its stops', or the direction's route with the most points (lowest id on
    /// a tie) when no route carries that id.
    private static func route(for stops: [BusStop], directionID: Int, routes: [BusRoute]) -> BusRoute? {
        if let matchingID = mostCommonRouteID(of: stops),
           let match = routes.first(where: { $0.routeID == matchingID }) {
            return match
        }
        return routes
            .filter { $0.directionID == directionID }
            .max { lhs, rhs in
                if lhs.geometry.points.count != rhs.geometry.points.count {
                    return lhs.geometry.points.count < rhs.geometry.points.count
                }
                return lhs.routeID > rhs.routeID
            }
    }

    /// `ID_RECORREGUT` shared by most stops of the direction; the lowest one
    /// wins a tie so the choice does not depend on dictionary order.
    private static func mostCommonRouteID(of stops: [BusStop]) -> Int? {
        var counts: [Int: Int] = [:]
        for stop in stops {
            counts[stop.routeID, default: 0] += 1
        }
        return counts.max { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value < rhs.value }
            return lhs.key > rhs.key
        }?.key
    }

    // MARK: - Projection

    /// Route distance of every stop, projected onto the geometry the same way
    /// `TrainPositionEngine` projects its stations, and kept non-decreasing so
    /// a polyline that doubles back cannot produce a negative interval.
    private static func stopDistances(of stops: [BusStop], on geometry: LineGeometry) -> [Double]? {
        guard !geometry.points.isEmpty else { return nil }
        let cumulative = GeoMath.cumulativeDistances(of: geometry.points)
        var distances: [Double] = []
        distances.reserveCapacity(stops.count)
        for stop in stops {
            let coordinate = GeoPoint(latitude: stop.latitude, longitude: stop.longitude)
            guard let projection = GeoMath.nearestProjection(of: coordinate, in: geometry.points, cumulative: cumulative) else {
                return nil
            }
            distances.append(max(projection.distance, distances.last ?? projection.distance))
        }
        return distances
    }
}
