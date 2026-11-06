import Foundation

/// The "Baixa a la pròxima" local notification (S8, D3): one pending request
/// at a time, rescheduled on every plan update and cancelled on stop.
///
/// Regular interruption level by decision D3: no time-sensitive entitlement
/// is requested, so the notification is an ordinary `.active` one. A
/// suspended app cannot poll, so the trigger date comes from the predicted
/// ETA of the alarm stop and is corrected on every reschedule.
@MainActor
enum FollowAlightScheduler {
    /// The one fixed request identifier of the scheduler.
    static let notificationID = "follow:alight"

    /// Replaces the pending alight notification with one at `date`, or only
    /// cancels it when `date` is nil.
    static func reschedule(at date: Date?, stopName: String, lineDisplayName: String) {
        ArrivalReminder.shared.cancel(id: notificationID)
        guard let date, date.timeIntervalSinceNow > 0 else { return }
        Task {
            await ArrivalReminder.shared.schedule(
                id: notificationID,
                title: "Baixa a la pròxima: \(stopName)",
                body: "\(lineDisplayName) · prepara't per baixar",
                at: date
            )
        }
    }

    /// Removes the pending alight notification.
    static func cancel() {
        ArrivalReminder.shared.cancel(id: notificationID)
    }
}
