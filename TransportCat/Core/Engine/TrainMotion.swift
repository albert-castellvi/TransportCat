import Foundation

/// Smooths the train markers between the 20 s arrival polls (spec S4).
///
/// The engine can only place a train where the feed says it is, so it jumps
/// every time a new poll lands. `TrainMotion` keeps a displayed route
/// distance per train, extrapolates the next poll's target along the polyline
/// and eases towards it at a bounded speed, which is what makes the map look
/// alive instead of teleporting.
///
/// It is a pure value type with no clock, no I/O and no randomness: every
/// method takes `now` and the result depends only on the calls made so far,
/// so its behaviour is unit-testable without a device.
///
/// Rules:
/// - `update` records a poll: an already known train keeps its displayed
///   distance and only re-anchors its target, a new train snaps to the
///   position the engine computed, and a train missing from the poll is
///   dropped.
/// - `advance` moves the markers: the target is the poll position plus the
///   distance the train covers at the engine speed since the poll, capped at
///   the station it is approaching. The displayed distance follows that
///   target at most `maxStepMetersPerSecond` per second of wall time, never
///   moves against the travel direction, and snaps when it is further than
///   `snapThresholdMeters` away.
/// - Only `routeDistance`, `position` and `heading` are interpolated; every
///   other field (`secondsToArrival`, `isDwelling`, direction...) stays as of
///   the last poll, because the feed only knows them once every 20 s. The
///   heading is interpolated like the position: it is the bearing at the drawn
///   point, not the one measured at the poll.
struct TrainMotion {
    /// Hard cap on how far a marker may move in one second, whatever the
    /// difference between the displayed point and the new poll.
    static let maxStepMetersPerSecond: Double = 24.0
    /// Distance beyond which the marker jumps instead of easing: a new train,
    /// a long gap in polling, or a genuinely impossible move.
    static let snapThresholdMeters: Double = 1500.0

    /// One train's animation state.
    private struct Track {
        /// Latest poll position, the source of every non-interpolated field
        /// and of the target distance.
        var train: TrainPosition
        /// Distance along the route currently drawn.
        var displayed: Double
        /// When the poll that produced `train` was recorded.
        var targetTime: Date
    }

    private var tracks: [String: Track] = [:]
    private var lastAdvance: Date?

    /// Records a new poll. Existing trains keep their displayed distance, new
    /// trains start at the computed position, and trains absent from `trains`
    /// disappear.
    mutating func update(with trains: [TrainPosition], now: Date) {
        var updated: [String: Track] = [:]
        for train in trains {
            if let existing = tracks[train.id] {
                updated[train.id] = Track(train: train, displayed: existing.displayed, targetTime: now)
            } else {
                updated[train.id] = Track(train: train, displayed: train.routeDistance, targetTime: now)
            }
        }
        tracks = updated
    }

    /// Advances every marker to `now`. Intended to be called once per second;
    /// the elapsed time is clamped to 0...5 s so a paused app does not read as
    /// a permanently running train.
    mutating func advance(to now: Date, engine: TrainPositionEngine) -> [TrainPosition] {
        let elapsed = lastAdvance.map { now.timeIntervalSince($0) } ?? 1
        let deltaTime = min(max(elapsed, 0), 5)
        lastAdvance = now

        var result: [TrainPosition] = []
        result.reserveCapacity(tracks.count)
        var advanced: [String: Track] = [:]
        for (id, track) in tracks {
            let train = track.train
            let direction: Double = train.forward ? 1 : -1
            // Distance still to cover before the station, and how far the
            // train has travelled since the poll.
            let remainingMeters = abs(train.segmentEndDistance - train.routeDistance)
            let travelled = engine.speed * max(0, now.timeIntervalSince(track.targetTime))
            let ideal = train.routeDistance + direction * min(travelled, remainingMeters)

            var displayed = track.displayed
            if abs(displayed - ideal) > Self.snapThresholdMeters {
                displayed = ideal
            } else {
                // Never move against the travel direction: a target that moved
                // back just holds the marker until a later poll overtakes it.
                let step = min(max(0, (ideal - displayed) * direction), Self.maxStepMetersPerSecond * deltaTime)
                displayed += direction * step
            }

            let point = engine.point(atRouteDistance: displayed) ?? train.position
            // S2: the bearing belongs to the drawn point and to the travel
            // direction, so a marker easing into a curve turns with it.
            let heading = engine.heading(atRouteDistance: displayed, forward: train.forward)
            result.append(train.moved(toRouteDistance: displayed, position: point, heading: heading))
            advanced[id] = Track(train: train, displayed: displayed, targetTime: track.targetTime)
        }
        tracks = advanced
        return result.sorted { $0.id < $1.id }
    }
}
