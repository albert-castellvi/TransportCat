import Foundation

/// The "Baixa a la pròxima" local notification (S8, D3): one pending request
/// at a time, rescheduled on every plan update and cancelled on stop.
///
/// CONTRACT (T0): the members below are fixed. T2 implements them through
/// `ArrivalReminder`'s notification plumbing.
@MainActor
enum FollowAlightScheduler {
    /// Replaces the pending alight notification with one at `date`, or only
    /// cancels it when `date` is nil.
    static func reschedule(at date: Date?, stopName: String, lineDisplayName: String) {}

    /// Removes the pending alight notification.
    static func cancel() {}
}
