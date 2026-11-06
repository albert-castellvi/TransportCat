import ActivityKit
import Foundation

/// The follow Live Activity (S8, D4): next stop, countdown, terminus and
/// progress to the alight stop on the lock screen and the Dynamic Island.
///
/// One follow activity at a time, local updates only (`pushType: nil`, the
/// same budget as the arrival activity). Starting one ends every arrival
/// activity (D4) so the lock screen never stacks two countdowns. Every call
/// is best effort — Live Activities can be disabled by the rider, and the
/// follow keeps working with the panel alone.
@MainActor
final class FollowActivityController {
    static let shared = FollowActivityController()

    /// How long the activity outlives its last update.
    static let staleInterval: TimeInterval = 120

    /// Scheduled ends keyed by activity id, cancelled by a refresh or an end.
    private var endTasks: [String: Task<Void, Never>] = [:]
    /// The contract members are synchronous, while every `Activity` call is
    /// async: work is chained so an `update` cannot slip between the end of
    /// the old activities and the request of the new one.
    private var work: Task<Void, Never>?

    private init() {}

    /// Whether the rider allows Live Activities at all.
    var isSupported: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    /// Starts the activity for a new follow session.
    func start(plan: FollowPlan) {
        enqueue {
            // D4: a follow supersedes the arrival activity.
            for other in Activity<ArrivalActivityAttributes>.activities {
                await other.end(nil, dismissalPolicy: .immediate)
            }
            // One follow activity at a time as well: a replaced session does
            // not leave its old activity on the lock screen.
            for other in Activity<FollowActivityAttributes>.activities {
                await other.end(nil, dismissalPolicy: .immediate)
            }
            guard self.isSupported else { return }

            let now = Date()
            let staleDate = now.addingTimeInterval(Self.staleInterval)
            let attributes = FollowActivityAttributes(
                lineDisplayName: plan.vehicle.lineDisplayName,
                lineColorHex: plan.vehicle.lineColorHex,
                textColorHex: HexLuminance.isLight(plan.vehicle.lineColorHex) ? "000000" : "FFFFFF",
                terminus: plan.vehicle.terminusName,
                mode: plan.vehicle.mode.rawValue
            )
            let content = ActivityContent(
                state: Self.contentState(for: plan, now: now),
                staleDate: staleDate
            )
            do {
                let activity = try Activity<FollowActivityAttributes>.request(
                    attributes: attributes,
                    content: content,
                    pushType: nil
                )
                scheduleEnd(of: activity, at: staleDate)
            } catch {
                // Best effort: the follow works without the activity.
            }
        }
    }

    /// Pushes the latest plan to the running activity.
    func update(plan: FollowPlan) {
        enqueue {
            guard let activity = Activity<FollowActivityAttributes>.activities.first else { return }
            let now = Date()
            let staleDate = now.addingTimeInterval(Self.staleInterval)
            let content = ActivityContent(
                state: Self.contentState(for: plan, now: now),
                staleDate: staleDate
            )
            scheduleEnd(of: activity, at: staleDate)
            await activity.update(content)
        }
    }

    /// Ends the activity (S9).
    func end() {
        enqueue {
            for activity in Activity<FollowActivityAttributes>.activities {
                endTasks[activity.id]?.cancel()
                endTasks[activity.id] = nil
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    // MARK: - Pure mapping (tested directly, see FollowActivityStateTests)

    /// The `ContentState` a plan draws, with the predicted arrivals placed at
    /// `now` plus each stop's ETA. FGC stops have no ETA (D1): names only.
    static func contentState(for plan: FollowPlan, now: Date) -> FollowActivityAttributes.ContentState {
        FollowActivityAttributes.ContentState(
            nextStopName: plan.next?.name,
            nextArrival: plan.next?.etaSeconds.map { now.addingTimeInterval(TimeInterval($0)) },
            alightStopName: plan.alight?.name,
            alightArrival: plan.alight?.etaSeconds.map { now.addingTimeInterval(TimeInterval($0)) },
            progress: plan.progressToAlight,
            isStale: false
        )
    }

    // MARK: - Helpers

    private func enqueue(_ body: @escaping () async -> Void) {
        let previous = work
        work = Task {
            await previous?.value
            await body()
        }
    }

    /// Ends the activity a little after its last update, if the app is still
    /// running: `dismissalPolicy: .after` keeps it on screen until then.
    private func scheduleEnd(of activity: Activity<FollowActivityAttributes>, at date: Date) {
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
}
