import Foundation

/// One leg a live train is travelling: from the last stop it was seen at to the
/// next stop Renfe's trip update predicts.
///
/// Distances are metres along the polyline of the train's direction, in travel
/// order, so `fromDistance` is always lower than `toDistance` on a valid leg.
/// `scheduledDeparture` and `scheduledDuration` come from the timetable pack;
/// `predictedArrival` comes from `RodaliesTripETA`. Everything is a value and
/// nothing reads a clock, so the estimate is a pure function of its inputs.
struct RodaliesTripLeg: Equatable {
    /// GTFS `stop_id` of the last stop known for the train.
    let fromStopID: String
    /// Distance of `fromStopID` along the direction's polyline, in metres.
    let fromDistance: Double
    /// GTFS `stop_id` of the next stop, from the trip update.
    let toStopID: String
    /// Distance of `toStopID` along the direction's polyline, in metres.
    let toDistance: Double
    /// Scheduled departure at `fromStopID`; nil when the pack does not know it.
    let scheduledDeparture: Date?
    /// Scheduled running time of the leg; nil when the pack cannot give it.
    /// The caller derives it from the pack's departure at both stops (the pack
    /// publishes departures, not arrivals).
    let scheduledDuration: TimeInterval?
    /// Predicted arrival at `toStopID`; nil when Renfe sends no usable ETA.
    let predictedArrival: Date?
    /// Whether the vehicle feed says `STOPPED_AT` at `fromStopID`.
    let isStoppedAtStation: Bool
}

/// Where an estimated Rodalies train is on one leg of its direction.
///
/// The vehicle feed mostly repeats the coordinate of a stop, so between polls
/// the map would be still. This estimate spreads a train over its leg with the
/// timetable and Renfe's predicted arrival; it is explicitly an estimate, never
/// a GPS fix, and every doubt degrades to `.none` so the caller draws the raw
/// feed point instead of inventing movement.
struct RodaliesTripProgress: Equatable {
    /// Which timing produced the estimate.
    ///
    /// - `eta`: Renfe's predicted arrival and the scheduled departure anchor it.
    /// - `scheduled`: the ETA was missing or impossible, the timetable's leg
    ///   duration did.
    /// - `stoppedAtStation`: the train has not reached its departure time (or
    ///   the pack does not know it), so it stays at `fromStopID`.
    /// - `none`: no trustworthy timing exists; the caller keeps the raw point.
    enum Estimate: Equatable {
        case eta
        case scheduled
        case stoppedAtStation
        case none
    }

    /// Metres along the direction's polyline where the train should be drawn.
    let distanceAlong: Double
    /// Fraction of the leg already covered, clamped to 0...1.
    let progress: Double
    /// Which timing produced `distanceAlong`.
    let estimate: Estimate

    /// A prediction older than five minutes is stale noise, not an ETA.
    static let etaPastTolerance: TimeInterval = 5 * 60
    /// A prediction more than an hour ahead cannot belong to a train that is
    /// already between two stops; it is a bad join or a service that has not
    /// started.
    static let etaFutureHorizon: TimeInterval = 60 * 60
    /// Beyond this separation the feed's own `IN_TRANSIT_TO` point is more
    /// trustworthy than the interpolation (spec A.7, level 2, point 5).
    static let feedPointPreferenceMeters: Double = 1_000

    /// Places the train on its leg at `now`.
    ///
    /// Rules, in order:
    /// 1. A leg that does not advance along the direction (`toDistance` not
    ///    after `fromDistance`) is rejected.
    /// 2. A `STOPPED_AT` train stays at `fromStopID` until its scheduled
    ///    departure; with no scheduled departure it stays, because nothing
    ///    proves it left.
    /// 3. With a plausible ETA (at most five minutes past, at most an hour
    ///    ahead, and after the departure) progress is
    ///    `(now - departure) / (eta - departure)`.
    /// 4. Otherwise the scheduled duration of the leg is used from the same
    ///    departure; without both, the result is `.none`.
    /// All progress values clamp to 0...1.
    static func estimate(for leg: RodaliesTripLeg, now: Date) -> RodaliesTripProgress {
        let from = leg.fromDistance
        let to = leg.toDistance
        guard from.isFinite, to.isFinite, to > from else {
            return RodaliesTripProgress(
                distanceAlong: from.isFinite ? from : 0,
                progress: 0,
                estimate: .none
            )
        }

        let departure = leg.scheduledDeparture
        let duration = leg.scheduledDuration.flatMap { $0 > 0 ? $0 : nil }

        if leg.isStoppedAtStation {
            guard let departure else {
                // No scheduled departure: the pack cannot prove the train has
                // left the platform, and the feed still points at the station.
                return make(0, from: from, to: to, estimate: .stoppedAtStation)
            }
            if now < departure {
                return make(0, from: from, to: to, estimate: .stoppedAtStation)
            }
        }

        if let departure, let eta = leg.predictedArrival,
           isPlausible(predictedArrival: eta, now: now),
           eta > departure {
            let span = eta.timeIntervalSince(departure)
            return make(now.timeIntervalSince(departure) / span, from: from, to: to, estimate: .eta)
        }

        if let departure, let duration {
            return make(now.timeIntervalSince(departure) / duration, from: from, to: to, estimate: .scheduled)
        }

        return make(0, from: from, to: to, estimate: .none)
    }

    /// Whether a predicted arrival is close enough to `now` to be used. The
    /// bounds are inclusive: five minutes late and one hour ahead are still
    /// plausible, anything beyond them is not. No clock is read here; `now` is
    /// the caller's.
    static func isPlausible(predictedArrival: Date, now: Date) -> Bool {
        let offset = predictedArrival.timeIntervalSince(now)
        return offset >= -etaPastTolerance && offset <= etaFutureHorizon
    }

    /// Whether the caller should keep the feed's own `IN_TRANSIT_TO` point
    /// instead of the interpolated one.
    ///
    /// Only meaningful for a train whose feed status is `IN_TRANSIT_TO`: for
    /// stop coordinates the interpolation is what adds movement. A separation
    /// over `thresholdMeters` means the ETA and the map disagree enough that
    /// Renfe's point is the safer truth.
    static func prefersFeedPoint(
        feedPoint: GeoPoint,
        interpolatedDistance: Double,
        points: [GeoPoint],
        cumulative: [Double],
        thresholdMeters: Double = feedPointPreferenceMeters
    ) -> Bool {
        guard let interpolated = GeoMath.point(at: interpolatedDistance, points: points, cumulative: cumulative) else {
            return true
        }
        return GeoMath.distanceMeters(from: feedPoint, to: interpolated) > thresholdMeters
    }

    /// Builds the result and clamps the fraction to the leg.
    private static func make(
        _ fraction: Double,
        from: Double,
        to: Double,
        estimate: Estimate
    ) -> RodaliesTripProgress {
        let clamped = fraction.isFinite ? min(max(fraction, 0), 1) : 0
        return RodaliesTripProgress(
            distanceAlong: from + (to - from) * clamped,
            progress: clamped,
            estimate: estimate
        )
    }
}
