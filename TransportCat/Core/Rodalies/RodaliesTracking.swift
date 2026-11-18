import Foundation

/// When each live train's reported position last actually changed, and the
/// rules that keep the map from claiming more than the feed knows.
///
/// Renfe's feed gives, for most vehicles, the coordinate of the stop rather
/// than a GPS fix, and re-publishes it with a fresh per-entity timestamp on
/// every poll. That timestamp is the moment the feed block was generated, not
/// the moment the position changed, so the only honest age is the client's
/// own: the last time the coordinate, or its projection on the track, moved by
/// more than `changeThresholdMeters`.
///
/// Pure value type: it takes `now` from the caller and has no clock of its own,
/// so the rules are tested at fixed dates.
struct RodaliesPositionTracking: Equatable {
    /// A movement below this is jitter, not news. Stop coordinates repeat to
    /// the metre; a GPS-ish point wobbles by a few metres between polls.
    static let changeThresholdMeters = 25.0

    struct Entry: Equatable {
        /// Last reported point, even when it did not count as a change.
        let position: GeoPoint
        /// Last reported distance along the drawn track, when it projected.
        let projectedDistance: Double?
        /// When the position last moved more than the threshold.
        let lastChangedAt: Date
    }

    private(set) var entries: [String: Entry] = [:]

    /// Registers one train's current reported point and projected distance and
    /// returns whether that counts as a position change. A first sighting
    /// counts: there is no earlier position to be stale against.
    @discardableResult
    mutating func update(
        trainID: String,
        position: GeoPoint,
        projectedDistance: Double?,
        now: Date
    ) -> Bool {
        guard let previous = entries[trainID] else {
            entries[trainID] = Entry(
                position: position,
                projectedDistance: projectedDistance,
                lastChangedAt: now
            )
            return true
        }
        let moved = GeoMath.distanceMeters(from: previous.position, to: position)
        let projectionMoved: Bool = {
            switch (previous.projectedDistance, projectedDistance) {
            case let (old?, new?):
                return abs(new - old) > Self.changeThresholdMeters
            case (nil, nil):
                return false
            default:
                // Gaining or losing a projection is a real change of what the
                // map can draw, even at the same coordinate.
                return true
            }
        }()
        let changed = moved > Self.changeThresholdMeters || projectionMoved
        entries[trainID] = Entry(
            position: position,
            projectedDistance: projectedDistance,
            lastChangedAt: changed ? now : previous.lastChangedAt
        )
        return changed
    }

    /// When the train's position last changed, or nil for a train never seen.
    func lastChangedAt(for trainID: String) -> Date? {
        entries[trainID]?.lastChangedAt
    }

    /// Age of the last change at `now`, never negative.
    func age(for trainID: String, now: Date) -> TimeInterval? {
        guard let changedAt = lastChangedAt(for: trainID) else { return nil }
        return max(0, now.timeIntervalSince(changedAt))
    }

    /// Forgets the trains no longer in the feed, so the table cannot grow with
    /// the day's churn of train numbers.
    mutating func prune(keeping trainIDs: Set<String>) {
        entries = entries.filter { trainIDs.contains($0.key) }
    }
}

/// Wording of the map card and the train sheet for a position that is not a
/// live GPS fix.
///
/// Kept beside the tracking rules so both surfaces say the same thing: the
/// caller supplies the age and the wording is decided once, in Catalan.
enum RodaliesPositionSourceText {
    /// The wording of a position interpolated between two stops from the
    /// timetable and Renfe's predicted arrival. It is an estimate by
    /// construction, so it never grows an age: the feed's stop coordinate being
    /// still is exactly what the estimate is working around.
    static var interpolated: String {
        String(localized: "Posició estimada amb l'horari i l'ETA de Renfe")
    }

    /// The estimate wording at `age`. Before the freshness threshold it only
    /// names the source; afterwards it says how long the position has been
    /// unchanged, which is the honest thing the feed can tell.
    static func estimated(age: TimeInterval?, now: Date) -> String {
        guard let age, age >= Freshness.staleAfter else {
            return String(localized: "Posició de Renfe")
        }
        return String(
            localized: "Posició de Renfe · sense canvi \(Freshness.ageText(since: now.addingTimeInterval(-age), now: now))"
        )
    }
}

/// One marker of the map: a representative vehicle and the trains that sit at
/// the same place. A group of one is the ordinary single-train marker.
struct RodaliesVehicleGroup: Identifiable, Equatable {
    /// The train the marker is drawn on, normally the lowest id of the group,
    /// so the drawing is deterministic across polls.
    let representative: MapVehicle
    /// Every train at this point, representative included, sorted by id.
    let members: [MapVehicle]

    var id: String { representative.id }
    var count: Int { members.count }
}

/// Groups vehicles that share a point, because Renfe publishes the stop
/// coordinate for most trains and a busy station otherwise shows one marker
/// hiding a dozen trains.
enum RodaliesVehicleGrouping {
    /// Trains closer than this are one marker. The feed repeats the same stop
    /// coordinate to the metre; the radius only needs to absorb the metre of
    /// projection noise.
    static let radiusMeters = 30.0

    /// Deterministic grouping: the lowest id of each cluster represents it, and
    /// only vehicles closer than `radius` to that representative are members.
    /// A pair exactly on the radius is not grouped, which keeps the output
    /// stable when two trains stop on opposite ends of a platform.
    static func groups(
        _ vehicles: [MapVehicle],
        radius: Double = radiusMeters
    ) -> [RodaliesVehicleGroup] {
        let ordered = vehicles.sorted { $0.id < $1.id }
        var assigned: Set<String> = []
        var result: [RodaliesVehicleGroup] = []
        result.reserveCapacity(ordered.count)
        for vehicle in ordered where !assigned.contains(vehicle.id) {
            var members: [MapVehicle] = []
            for other in ordered where !assigned.contains(other.id) {
                let distance = GeoMath.distanceMeters(from: vehicle.position, to: other.position)
                if other.id == vehicle.id || distance < radius {
                    members.append(other)
                }
            }
            for member in members { assigned.insert(member.id) }
            result.append(RodaliesVehicleGroup(representative: vehicle, members: members))
        }
        return result
    }
}

/// Whether a drawn position is an estimate of the feed's point rather than the
/// feed's point itself.
///
/// The map snaps a projectable train onto its track and glides it between
/// polls, so that drawn point is an interpolation. A raw point is the feed's
/// own coordinate only for an `IN_TRANSIT_TO` vehicle; an `INCOMING_AT` or
/// `STOPPED_AT` entity carries the stop's coordinate, which is an estimate of
/// where the train is, not a fix.
enum RodaliesPositionEstimate {
    static func isEstimated(status: String?, isSnapped: Bool) -> Bool {
        if isSnapped { return true }
        return status != "IN_TRANSIT_TO"
    }
}

/// How the map moves a train between two polls.
enum RodaliesMotionTransition {
    /// A jump this large is a stop reassignment, not travel: the feed moved
    /// the train from one stop to the next, which can be kilometres. Same
    /// value as `FGCNetwork.maxSnapOffsetMeters`.
    static let reassignmentThresholdMeters = 300.0
    /// Duration of the short transition used for a reassignment.
    static let shortTransitionSeconds: TimeInterval = 0.4

    /// Glide duration for a jump of `jump` metres: the full poll interval for a
    /// small move (a real fix), a short transition for a stop reassignment, so
    /// the marker never flies a kilometre at 600 km/h.
    static func duration(forJumpMeters jump: Double, pollDuration: TimeInterval) -> TimeInterval {
        abs(jump) > reassignmentThresholdMeters ? shortTransitionSeconds : pollDuration
    }
}

/// Sanity of a Renfe point against its line.
///
/// A corrupted feed record can place a train 100 km away from its own track
/// (the review found R4 77552 reported at Planoles). Drawing that raw point
/// puts a train on the wrong part of the map, so a point that far is not drawn
/// at all instead of being moved somewhere it does not belong.
enum RodaliesPositionSanity {
    /// Points farther than this from their line are not drawn.
    static let maximumDistanceFromLineMeters = 5_000.0
    /// Points this close to the track are drawn on it, like FGC's snap.
    static let snapThresholdMeters = FGCNetwork.maxSnapOffsetMeters

    /// What the map does with a point at a known offset from its line.
    enum Placement: Equatable {
        /// Draw it on the track (projected and interpolated).
        case snapped
        /// Draw it at the reported point: close enough to belong to the map,
        /// too far from the track to claim it is on it.
        case raw
        /// Do not draw it: the record does not belong to this line.
        case hidden
    }

    /// Placement of a point at `offsetMeters`, nil when no track is known (the
    /// map cannot judge it and draws it raw).
    static func placement(offsetMeters: Double?) -> Placement {
        guard let offsetMeters else { return .raw }
        if offsetMeters > maximumDistanceFromLineMeters { return .hidden }
        if offsetMeters <= snapThresholdMeters { return .snapped }
        return .raw
    }

    /// Nearest point of `point` on any polyline of `geometry`, with no distance
    /// cap: the caller decides whether the point is close enough to snap, far
    /// enough to hide, or in between.
    static func nearestProjection(of point: GeoPoint, in geometry: FGCLineGeometry) -> LineProjection? {
        guard geometry.polylines.count == geometry.cumulative.count else { return nil }
        var best: LineProjection?
        for index in geometry.polylines.indices {
            let points = geometry.polylines[index]
            let cumulative = geometry.cumulative[index]
            guard !points.isEmpty,
                  let projection = GeoMath.nearestProjection(of: point, in: points, cumulative: cumulative)
            else { continue }
            if let current = best, current.offsetMeters <= projection.offsetMeters { continue }
            best = LineProjection(
                distance: projection.distance,
                heading: FGCNetwork.heading(at: projection.distance, points: points, cumulative: cumulative),
                offsetMeters: projection.offsetMeters
            )
        }
        return best
    }

    /// A point projected on one line's track, uncapped.
    struct LineProjection: Equatable {
        let distance: Double
        let heading: Double
        let offsetMeters: Double
    }
}
