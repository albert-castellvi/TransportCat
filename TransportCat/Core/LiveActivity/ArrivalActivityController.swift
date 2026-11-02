import ActivityKit
import Foundation

/// Identifies the running Live Activity of one place (spec S20).
struct ArrivalActivityHandle: Identifiable, Equatable {
    let id: String
    let placeID: String
    let lineCode: String
    let destination: String
}

/// Starts, refreshes and ends the "Segueix en directe" Live Activity
/// (spec S20).
///
/// The app runs one tracked arrival at a time: starting a second one ends the
/// previous one, so the lock screen never stacks stale countdowns. Every call
/// is best effort — Live Activities can be disabled by the rider, and the app
/// keeps working with the countdown in the sheet alone.
@MainActor
final class ArrivalActivityController {
    static let shared = ArrivalActivityController()

    /// How long the activity outlives the expected arrival (spec S20).
    static let staleInterval: TimeInterval = 120

    /// Scheduled ends keyed by activity id, cancelled when a refresh moves the
    /// arrival.
    private var endTasks: [String: Task<Void, Never>] = [:]

    private init() {}

    /// Whether the rider allows Live Activities at all.
    var isSupported: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    /// The activity already tracking `placeID`, if any.
    func runningActivity(forPlace placeID: String) -> ArrivalActivityHandle? {
        guard let activity = Activity<ArrivalActivityAttributes>.activities
            .first(where: { $0.attributes.placeID == placeID }) else { return nil }
        return ArrivalActivityHandle(
            id: activity.id,
            placeID: placeID,
            lineCode: activity.attributes.lineCode,
            destination: activity.attributes.destination
        )
    }

    /// Starts tracking one arrival and returns the new activity id, or nil
    /// when Live Activities are unavailable.
    @discardableResult
    func start(
        placeID: String,
        placeName: String,
        lineCode: String,
        lineName: String,
        lineColorHex: String,
        destination: String,
        arrivalDate: Date,
        minutes: Int?
    ) async -> String? {
        guard isSupported else { return nil }

        // One activity at a time: the rider asked to follow this arrival now.
        for other in Activity<ArrivalActivityAttributes>.activities {
            await other.end(nil, dismissalPolicy: .immediate)
            endTasks[other.id]?.cancel()
            endTasks[other.id] = nil
        }

        let attributes = ArrivalActivityAttributes(
            placeID: placeID,
            placeName: placeName,
            lineCode: lineCode,
            lineName: lineName,
            lineColorHex: lineColorHex,
            textColorHex: HexLuminance.isLight(lineColorHex) ? "000000" : "FFFFFF",
            destination: destination
        )
        let staleDate = arrivalDate.addingTimeInterval(Self.staleInterval)
        let content = ActivityContent(
            state: Self.state(arrivalDate: arrivalDate, minutes: minutes),
            staleDate: staleDate
        )

        do {
            let activity = try Activity<ArrivalActivityAttributes>.request(
                attributes: attributes,
                content: content,
                pushType: nil
            )
            scheduleEnd(of: activity, at: staleDate)
            return activity.id
        } catch {
            return nil
        }
    }

    /// Moves the running activity to a refreshed arrival (spec S20). The
    /// sheets call this after every arrivals load while the app is running.
    func update(id: String, arrivalDate: Date) {
        guard let activity = Activity<ArrivalActivityAttributes>.activities
            .first(where: { $0.id == id }) else { return }
        let staleDate = arrivalDate.addingTimeInterval(Self.staleInterval)
        let content = ActivityContent(
            state: Self.state(
                arrivalDate: arrivalDate,
                minutes: Self.minutes(until: arrivalDate)
            ),
            staleDate: staleDate
        )
        scheduleEnd(of: activity, at: staleDate)
        Task { await activity.update(content) }
    }

    /// Ends a tracked activity right away, e.g. when the rider taps the
    /// button again or leaves the sheet.
    func end(id: String) {
        endTasks[id]?.cancel()
        endTasks[id] = nil
        guard let activity = Activity<ArrivalActivityAttributes>.activities
            .first(where: { $0.id == id }) else { return }
        let dismissal = Date()
        Task { await activity.end(nil, dismissalPolicy: .after(dismissal)) }
    }

    // MARK: - Helpers

    /// Ends the activity a little after the arrival, if the app is still
    /// running: `dismissalPolicy: .after` keeps it on screen until then.
    private func scheduleEnd(of activity: Activity<ArrivalActivityAttributes>, at date: Date) {
        endTasks[activity.id]?.cancel()
        endTasks[activity.id] = Task { [weak self] in
            let delay = date.timeIntervalSinceNow
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            await activity.end(nil, dismissalPolicy: .after(date))
            self?.endTasks[activity.id] = nil
        }
    }

    private static func state(arrivalDate: Date, minutes: Int?) -> ArrivalActivityAttributes.ContentState {
        ArrivalActivityAttributes.ContentState(
            arrivalDate: arrivalDate,
            minutes: minutes,
            isStale: arrivalDate.timeIntervalSinceNow < -60
        )
    }

    /// Rounded-up minutes left, the same reading as the sheets.
    private static func minutes(until date: Date) -> Int? {
        let seconds = date.timeIntervalSinceNow
        guard seconds > 0 else { return 0 }
        return Int(ceil(seconds / 60))
    }
}
