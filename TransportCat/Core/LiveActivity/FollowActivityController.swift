import Foundation

/// The follow Live Activity (S8, D4): next stop, countdown, terminus and
/// progress to the alight stop on the lock screen and the Dynamic Island.
///
/// CONTRACT (T0): the members below are fixed. T2 implements them over a new
/// `FollowActivityAttributes` (app and widget targets) and ends any arrival
/// activity when a follow starts.
@MainActor
final class FollowActivityController {
    static let shared = FollowActivityController()

    /// Starts the activity for a new follow session.
    func start(plan: FollowPlan) {}

    /// Pushes the latest plan to the running activity.
    func update(plan: FollowPlan) {}

    /// Ends the activity (S9).
    func end() {}
}
