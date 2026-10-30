import Foundation

/// Smoothes the train markers between the 20 s arrival polls (spec S1).
///
/// The engine can only place a train where the feed says it is, so it jumps
/// every time a new poll lands. `TrainMotion` keeps a displayed route
/// distance and a velocity per train, extrapolates the next poll's target
/// along the polyline and drives the marker toward it with a
/// velocity controller: proportional on the distance error, capped by a
/// maximum speed and by an acceleration limit. That is what makes the map
/// look alive instead of teleporting, and what removes the speed jerks a
/// plain position clamp produced.
///
/// It is a pure value type with no clock, no I/O and no randomness: every
/// method takes `now` and the result depends only on the calls made so far,
/// so its behaviour is unit-testable without a device.
///
/// Rules:
/// - `update` records a poll: an already known train keeps its displayed
///   distance and velocity and only re-anchors its target, a new train snaps
///   to the position the engine computed (and takes the engine speed as its
///   initial velocity), and a train missing from the poll is dropped.
/// - `advance` moves the markers once per tick. For each train, with `dir`
///   the travel direction as +1 (forward) or -1 (backward):
///   1. `ideal` is the poll position plus the distance covered at the engine
///      speed since the poll, capped at the station it is approaching.
///   2. `error = (ideal - displayed) * dir`, positive when the marker is
///      behind its target.
///   3. `desired = clamp(engineSpeed + velocityGain * error, 0, maxVelocity)`.
///   4. Braking: `desired = min(desired, sqrt(2 * brakingDeceleration *
///      remaining))`, where `remaining` is the distance still to travel to
///      the segment end, so the marker eases into the platform instead of
///      hitting it at line speed.
///   5. The velocity moves toward `desired` by at most `maxAcceleration * dt`
///      and is clamped to `0...maxVelocity`.
///   6. `displayed += dir * velocity * dt`, never past the segment end and
///      never against the travel direction (the velocity is never negative).
///   A gap larger than `snapThresholdMeters` between the drawn point and the
///   target snaps instead of easing, and re-anchors the velocity to the
///   engine speed.
/// - Only `routeDistance`, `position` and `heading` are interpolated; every
///   other field (`secondsToArrival`, `isDwelling`, direction...) stays as of
///   the last poll, because the feed only knows them once every 20 s. The
///   heading is interpolated like the position: it is the bearing at the drawn
///   point, not the one measured at the poll.
struct TrainMotion {
    /// Proportional gain of the velocity controller, in m/s per meter of
    /// error between the drawn point and its target.
    static let velocityGain: Double = 0.1
    /// Hard cap on velocity, in m/s, whatever the error asks for. Well above
    /// the engine speed (8 m/s) so the marker can catch up after a poll
    /// without ever looking like a teleport.
    static let maxVelocity: Double = 12.0
    /// Acceleration limit of the controller, in m/s². Also the deceleration
    /// the braking curve assumes, so the marker stops at the platform with a
    /// smooth slowdown instead of a step.
    static let maxAcceleration: Double = 4.0
    /// Deceleration of the brake curve toward a station: half the acceleration
    /// limit, so the controller can always follow the curve. At the full limit
    /// the last step of every stop was an abrupt 2-3 m/s halt (measured on live
    /// L1/L3/L5 data).
    static let brakingDeceleration: Double = 2.0
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
        /// Speed of the drawn marker along the travel direction, in m/s.
        /// `nil` until the first advance establishes it: `update` has no
        /// engine, so a new train takes the engine speed on that first tick.
        var velocity: Double?
        /// When the poll that produced `train` was recorded.
        var targetTime: Date
    }

    private var tracks: [String: Track] = [:]
    private var lastAdvance: Date?

    /// Records a new poll. Existing trains keep their displayed distance and
    /// velocity, new trains start at the computed position, and trains absent
    /// from `trains` disappear.
    mutating func update(with trains: [TrainPosition], now: Date) {
        var updated: [String: Track] = [:]
        for train in trains {
            if let existing = tracks[train.id] {
                updated[train.id] = Track(
                    train: train,
                    displayed: existing.displayed,
                    velocity: existing.velocity,
                    targetTime: now
                )
            } else {
                updated[train.id] = Track(
                    train: train,
                    displayed: train.routeDistance,
                    velocity: nil,
                    targetTime: now
                )
            }
        }
        tracks = updated
    }

    /// Advances every marker to `now`. Intended to be called at the display
    /// tick rate (10 Hz); the elapsed time is clamped to 0...5 s so a paused
    /// app does not read as a permanently running train, and a zero-length
    /// step publishes the current state without moving anything.
    mutating func advance(to now: Date, engine: TrainPositionEngine) -> [TrainPosition] {
        let elapsed = lastAdvance.map { now.timeIntervalSince($0) } ?? 0
        let deltaTime = min(max(elapsed, 0), 5)
        lastAdvance = now

        guard deltaTime > 0 else {
            return tracks.map { published(track: $0.value, displayed: $0.value.displayed, engine: engine) }
                .sorted { $0.id < $1.id }
        }

        var result: [TrainPosition] = []
        result.reserveCapacity(tracks.count)
        var advanced: [String: Track] = [:]
        for (id, track) in tracks {
            let train = track.train
            let direction: Double = train.forward ? 1 : -1

            // Distance still to cover before the station, and how far the
            // train has travelled since the poll.
            let pollRemaining = max(0, (train.segmentEndDistance - train.routeDistance) * direction)
            let travelled = engine.speed * max(0, now.timeIntervalSince(track.targetTime))
            let ideal = train.routeDistance + direction * min(travelled, pollRemaining)

            var displayed = track.displayed
            var velocity = track.velocity ?? engine.speed
            if abs(ideal - displayed) > Self.snapThresholdMeters {
                // Too far to ease: jump the marker and restart from the
                // engine speed, which is what a fresh train would do.
                displayed = ideal
                velocity = engine.speed
            } else {
                // Distance still to the segment end at the drawn point.
                let remaining = max(0, (train.segmentEndDistance - displayed) * direction)
                // Positive when the marker is behind its target.
                let error = (ideal - displayed) * direction
                var desired = min(max(engine.speed + Self.velocityGain * error, 0), Self.maxVelocity)
                // Brake before the station: the fastest speed from which the
                // acceleration limit still stops the marker at the platform.
                desired = min(desired, (2 * Self.brakingDeceleration * remaining).squareRoot())
                let maxChange = Self.maxAcceleration * deltaTime
                velocity = min(max(velocity + min(max(desired - velocity, -maxChange), maxChange), 0), Self.maxVelocity)
                displayed += direction * velocity * deltaTime

                // Never cross the platform. A marker already past a newly
                // polled segment end keeps its distance instead of reversing:
                // a train never moves against its travel direction.
                let wasPastEnd = (track.displayed - train.segmentEndDistance) * direction > 0
                let isPastEnd = (displayed - train.segmentEndDistance) * direction > 0
                if isPastEnd && !wasPastEnd {
                    displayed = train.segmentEndDistance
                }
            }

            result.append(published(track: track, displayed: displayed, engine: engine))
            advanced[id] = Track(train: train, displayed: displayed, velocity: velocity, targetTime: track.targetTime)
        }
        tracks = advanced
        return result.sorted { $0.id < $1.id }
    }

    /// Publishes a track at `displayed`: the point and the bearing belong to
    /// the drawn distance, every other field is the poll's.
    private func published(track: Track, displayed: Double, engine: TrainPositionEngine) -> TrainPosition {
        let train = track.train
        let point = engine.point(atRouteDistance: displayed) ?? train.position
        // S2: the bearing belongs to the drawn point and to the travel
        // direction, so a marker easing into a curve turns with it.
        let heading = engine.heading(atRouteDistance: displayed, forward: train.forward)
        return train.moved(toRouteDistance: displayed, position: point, heading: heading)
    }
}
