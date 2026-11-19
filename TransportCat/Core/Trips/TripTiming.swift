import Foundation

/// Which part of a trip the rider is in, planned from the saved legs (spec
/// S4). It is the conservative plan only: the live layer (T2) merges it with
/// real-time positions and departures.
enum TripPhase: Equatable {
    /// Waiting for the first ride; the walk before it happens inside this
    /// phase.
    case waiting(legIndex: Int)
    /// On the vehicle of `legIndex`.
    case riding(legIndex: Int)
    /// Walking towards the ride at `toLegIndex`.
    case transfer(toLegIndex: Int)
    /// The last ride finished; the final walk happens inside this phase.
    case arrived
}

/// Planned-time arithmetic of a saved trip, kept Foundation-only so it runs
/// in the Linux harness.
enum TripTiming {
    /// The first departure the rider can reach when they get there at
    /// `earliest` and need `margin` to board. Nil when the service is done.
    static func nextCatchable(after earliest: Date, departures: [Date], margin: TimeInterval = 60) -> Date? {
        let threshold = earliest.addingTimeInterval(margin)
        return departures.sorted().first { $0 >= threshold }
    }

    /// Seconds between arriving at the stop and the vehicle leaving; negative
    /// when the connection is missed.
    static func transferMargin(arrival: Date, walkSeconds: Int, departure: Date) -> TimeInterval {
        departure.timeIntervalSince(arrival) - TimeInterval(walkSeconds)
    }

    /// When the trip is planned to arrive, following its legs from
    /// `startedAt`: the walks before rides are the waits, the next ride's walk
    /// before it is the transfer, and the final walk closes the trip.
    static func plannedArrival(trip: SavedTrip, startedAt: Date) -> Date {
        let timeline = plannedTimeline(trip: trip, startedAt: startedAt)
        let endOfLastRide = timeline.reaches.last ?? startedAt
        return endOfLastRide.addingTimeInterval(TimeInterval(trip.finalWalkSeconds))
    }

    /// The planned phase at `now`. Conservative: before the start it is the
    /// wait for the first ride, after the arrival it is `arrived`.
    static func plannedPhase(trip: SavedTrip, startedAt: Date, now: Date) -> TripPhase {
        let timeline = plannedTimeline(trip: trip, startedAt: startedAt)
        guard let firstDeparture = timeline.departures.first else {
            return .arrived
        }
        if now < firstDeparture {
            return .waiting(legIndex: 0)
        }
        for index in timeline.departures.indices {
            // From the transfer's walk until the next ride leaves, the rider
            // is walking to (and waiting at) the next stop.
            if now < timeline.departures[index] {
                return .transfer(toLegIndex: index)
            }
            if now < timeline.reaches[index] {
                return .riding(legIndex: index)
            }
        }
        return .arrived
    }

    // MARK: - Timeline

    /// Instants of a trip run: `departures[i]` is when the ride `i` starts
    /// and `reaches[i]` when the ride `i` ends (the same instant the next
    /// transfer starts). The arrival is the `reaches` of the last ride plus
    /// the final walk, which `plannedArrival` adds.
    struct Timeline: Equatable {
        let departures: [Date]
        let reaches: [Date]
    }

    static func plannedTimeline(trip: SavedTrip, startedAt: Date) -> Timeline {
        var departures: [Date] = []
        var reaches: [Date] = []
        var cursor = startedAt
        for leg in trip.legs {
            cursor = cursor.addingTimeInterval(TimeInterval(leg.walkSecondsBefore))
            departures.append(cursor)
            cursor = cursor.addingTimeInterval(TimeInterval(leg.rideSeconds))
            reaches.append(cursor)
        }
        return Timeline(departures: departures, reaches: reaches)
    }
}
