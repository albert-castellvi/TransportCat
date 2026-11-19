import Foundation
import Observation

/// The one trip being followed on the maps (spec S4): when it started, so the
/// planned timeline can be walked from that instant.
struct ActiveTrip: Codable, Hashable {
    let tripID: UUID
    let startedAt: Date
}

/// Saved, habitual and recent trips, and the one active trip, persisted in
/// `UserDefaults` (spec S4).
///
/// Lists live under their own versioned keys so a model change can migrate
/// one without touching the other. Both are read tolerantly: a value that is
/// not our JSON reads as empty instead of crashing.
///
/// `SavedTrip` is immutable: edits (`rename`, `setKind`, `start`) replace the
/// stored value, so a trip cannot be half-updated between reads.
@Observable
final class TripsStore {
    static let shared = TripsStore()

    static let tripsKey = "savedTrips.v1"
    static let activeTripKey = "activeTrip.v1"

    /// Most recent trips kept; the oldest is dropped beyond this.
    static let recentLimit = 5
    /// Most habitual trips kept; saving one more demotes the oldest.
    static let habitualLimit = 4

    /// A trip whose planned arrival plus this slack is in the past is no
    /// longer followed: the rider got off, or the app was away too long.
    static let staleGrace: TimeInterval = 90 * 60

    private let defaults: UserDefaults

    /// Every stored trip, in no particular order; use `ordered` to show them.
    private(set) var trips: [SavedTrip]
    /// The trip being followed, nil when none is.
    private(set) var activeTrip: ActiveTrip?

    /// - Parameter defaults: injectable suite, so tests do not touch the app's
    ///   domain.
    init(defaults: UserDefaults = FavoritesStore.sharedDefaults) {
        self.defaults = defaults
        trips = Self.read([SavedTrip].self, key: Self.tripsKey, defaults: defaults) ?? []
        activeTrip = Self.read(ActiveTrip.self, key: Self.activeTripKey, defaults: defaults)
        expireIfStale(now: Date())
    }

    // MARK: - Reading

    /// Habitual trips first, then saved, then recent; each group most recently
    /// used first, then most recently created.
    var ordered: [SavedTrip] {
        trips.sorted { lhs, rhs in
            if lhs.kind.rank != rhs.kind.rank {
                return lhs.kind.rank < rhs.kind.rank
            }
            let lhsUsed = lhs.lastUsedAt ?? lhs.createdAt
            let rhsUsed = rhs.lastUsedAt ?? rhs.createdAt
            if lhsUsed != rhsUsed {
                return lhsUsed > rhsUsed
            }
            return lhs.createdAt > rhs.createdAt
        }
    }

    func trip(id: UUID) -> SavedTrip? {
        trips.first { $0.id == id }
    }

    /// The trip being followed, or nil when there is none or it is stale.
    var activeSavedTrip: SavedTrip? {
        guard let activeTrip else { return nil }
        return trip(id: activeTrip.tripID)
    }

    // MARK: - Saving

    /// Stores the trip as `kind` and returns what was stored.
    ///
    /// A trip with the same `signature` is the same trip: its stored copy
    /// replaces its kind with `kind` unless that would demote a habitual to
    /// recent, and the stored copy is returned, so a rider saving it twice
    /// gets one entry. Recents and habituals are then capped, the least
    /// recently used leaving first.
    @discardableResult
    func save(_ trip: SavedTrip, as kind: TripKind) -> SavedTrip {
        guard let index = trips.firstIndex(where: { $0.signature == trip.signature }) else {
            let stored = Self.retagged(trip, as: kind)
            trips.append(stored)
            enforceLimits()
            persist()
            return self.trip(id: stored.id) ?? stored
        }

        let stored = Self.retagged(trips[index], as: Self.merged(trips[index].kind, and: kind))
        trips[index] = stored
        enforceLimits()
        persist()
        return self.trip(id: stored.id) ?? stored
    }

    /// The kind a trip ends up with when `kind` is asked for on a trip that
    /// currently is `current`: never below saved, so a habitual or saved trip
    /// opened again does not fall back to recent.
    static func merged(_ current: TripKind, and kind: TripKind) -> TripKind {
        if kind == .recent, current != .recent {
            return current
        }
        return kind
    }

    /// A copy of the trip with another kind.
    private static func retagged(_ trip: SavedTrip, as kind: TripKind) -> SavedTrip {
        SavedTrip(
            id: trip.id,
            name: trip.name,
            originName: trip.originName,
            destinationName: trip.destinationName,
            origin: trip.origin,
            destination: trip.destination,
            kind: kind,
            createdAt: trip.createdAt,
            lastUsedAt: trip.lastUsedAt,
            legs: trip.legs,
            finalWalkSeconds: trip.finalWalkSeconds,
            plannedDurationSeconds: trip.plannedDurationSeconds
        )
    }

    /// A copy of the trip renamed and, when given, used at `now`.
    private static func updated(_ trip: SavedTrip, name: String? = nil, lastUsedAt: Date? = nil) -> SavedTrip {
        SavedTrip(
            id: trip.id,
            name: name ?? trip.name,
            originName: trip.originName,
            destinationName: trip.destinationName,
            origin: trip.origin,
            destination: trip.destination,
            kind: trip.kind,
            createdAt: trip.createdAt,
            lastUsedAt: lastUsedAt ?? trip.lastUsedAt,
            legs: trip.legs,
            finalWalkSeconds: trip.finalWalkSeconds,
            plannedDurationSeconds: trip.plannedDurationSeconds
        )
    }

    /// Drops the least recently used recents beyond the cap and demotes the
    /// least recently used habituals beyond theirs to saved.
    private func enforceLimits() {
        let recents = trips.filter { $0.kind == .recent }
        if recents.count > Self.recentLimit {
            let excess = Set(
                recents.sorted(by: Self.leastRecentlyUsed).prefix(recents.count - Self.recentLimit).map(\.id)
            )
            trips.removeAll { excess.contains($0.id) }
            if let activeTrip, excess.contains(activeTrip.tripID) {
                setActive(nil)
            }
        }

        let habituals = trips.filter { $0.kind == .habitual }
        if habituals.count > Self.habitualLimit {
            let demoted = Set(
                habituals.sorted(by: Self.leastRecentlyUsed).prefix(habituals.count - Self.habitualLimit).map(\.id)
            )
            trips = trips.map { demoted.contains($0.id) ? Self.retagged($0, as: .saved) : $0 }
        }
    }

    /// Last used first, then last created; the order recents and habituals
    /// leave in when at their cap.
    private static func leastRecentlyUsed(_ lhs: SavedTrip, _ rhs: SavedTrip) -> Bool {
        let lhsUsed = lhs.lastUsedAt ?? lhs.createdAt
        let rhsUsed = rhs.lastUsedAt ?? rhs.createdAt
        if lhsUsed != rhsUsed {
            return lhsUsed < rhsUsed
        }
        return lhs.createdAt < rhs.createdAt
    }

    // MARK: - Editing

    func remove(id: UUID) {
        guard trips.contains(where: { $0.id == id }) else { return }
        trips.removeAll { $0.id == id }
        if activeTrip?.tripID == id {
            setActive(nil)
        }
        persist()
    }

    /// Renames a trip; a blank name is ignored so the pill never reads empty.
    func rename(id: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = trips.firstIndex(where: { $0.id == id }) else { return }
        trips[index] = Self.updated(trips[index], name: name)
        persist()
    }

    /// Moves a trip to another kind, honouring the same caps as `save`.
    func setKind(id: UUID, _ kind: TripKind) {
        guard let index = trips.firstIndex(where: { $0.id == id }) else { return }
        trips[index] = Self.retagged(trips[index], as: kind)
        enforceLimits()
        persist()
    }

    // MARK: - Following

    /// Starts following a known trip: it becomes the active one and its
    /// `lastUsedAt` is stamped.
    func start(id: UUID, now: Date = Date()) {
        expireIfStale(now: now)
        guard let index = trips.firstIndex(where: { $0.id == id }) else { return }
        trips[index] = Self.updated(trips[index], lastUsedAt: now)
        setActive(ActiveTrip(tripID: id, startedAt: now))
        persist()
    }

    /// Follows a trip straight from the planner: an unknown one is saved as
    /// recent first, then started.
    func start(trip: SavedTrip, now: Date = Date()) {
        expireIfStale(now: now)
        if self.trip(id: trip.id) == nil {
            save(trip, as: .recent)
        }
        start(id: trip.id, now: now)
    }

    func endActive() {
        guard activeTrip != nil else { return }
        setActive(nil)
        persist()
    }

    /// Ends the active trip when its planned arrival (plus `staleGrace`) is
    /// already past at `now`.
    func expireIfStale(now: Date = Date()) {
        guard let activeTrip, let trip = trip(id: activeTrip.tripID) else { return }
        let plannedArrival = TripTiming.plannedArrival(trip: trip, startedAt: activeTrip.startedAt)
        guard plannedArrival.addingTimeInterval(Self.staleGrace) < now else { return }
        setActive(nil)
        persist()
    }

    private func setActive(_ value: ActiveTrip?) {
        activeTrip = value
        if let value, let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: Self.activeTripKey)
        } else {
            defaults.removeObject(forKey: Self.activeTripKey)
        }
    }

    // MARK: - Persistence

    private func persist() {
        Self.write(trips, key: Self.tripsKey, defaults: defaults)
    }

    private static func read<T: Decodable>(_ type: T.Type, key: String, defaults: UserDefaults) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func write<T: Encodable>(_ value: T, key: String, defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }
}
