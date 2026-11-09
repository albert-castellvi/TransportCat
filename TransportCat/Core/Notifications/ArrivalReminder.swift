import Foundation
import UserNotifications

/// Arrival reminders (spec S13): one local notification per reminder, with the
/// list of scheduled ids kept in memory and mirrored in UserDefaults, so an
/// arrival row can show "Avisa'm" as already set after a relaunch.
///
/// Permission (alert + sound) is asked on the first use. `schedule` returns
/// false when permission was denied or the date already passed. Notifications
/// that arrive while the app is in the foreground show as banners, through the
/// delegate installed when the shared instance is created at launch.
@MainActor
final class ArrivalReminder {
    static let shared = ArrivalReminder()

    /// Versioned UserDefaults key holding `id -> fire date` as JSON. This is
    /// the persisted mirror of the in-memory scheduled set (contract S13).
    nonisolated static let storageKey = "scheduledReminders.v1"

    private let center: UNUserNotificationCenter
    private let defaults: UserDefaults
    /// Scheduled reminders by id; entries whose date passed are pruned.
    private var scheduled: [String: Date] = [:]
    /// Permission asked once per launch; nil until the first ask.
    private var permissionGranted: Bool?

    /// The system keeps the notification delegate weak, so a singleton owns it.
    nonisolated private static let bannerDelegate = NotificationBannerDelegate()

    init(center: UNUserNotificationCenter = .current(), defaults: UserDefaults = .standard) {
        self.center = center
        self.defaults = defaults
        loadScheduled()
        pruneExpired(now: Date())
        center.delegate = Self.bannerDelegate
    }

    // MARK: - Contract API (consumed by the arrival rows and the watcher)

    /// The identifier of one reminder: `"<placeId>|<línia>|<destí>|<servei>|<n>"`.
    ///
    /// One id per train and lead time (spec S13). The train code is part of the
    /// id because a line serves the same destination with several trains at
    /// once: without it the second reminder of a destination replaced the first
    /// and only one of the two rows the rider picked was ever announced. When
    /// the feed gives no train code there is nothing to tell two trains apart,
    /// and the row falls back to the destination and lead time alone.
    nonisolated static func reminderID(
        placeID: String,
        lineLabel: String,
        destination: String,
        serviceCode: String?,
        minutesBefore: Int
    ) -> String {
        "\(placeID)|\(lineLabel)|\(destination)|\(serviceCode ?? "-")|\(minutesBefore)"
    }

    /// Schedules a reminder for `at`, asking permission on first use. Returns
    /// false when permission is denied, the date lies in the past, or the
    /// system refuses the request. An id that is already scheduled is replaced.
    func schedule(id: String, title: String, body: String, at: Date) async -> Bool {
        guard at.timeIntervalSinceNow > 0 else { return false }
        guard await ensurePermissionGranted() else { return false }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: at
        )
        let request = UNNotificationRequest(
            identifier: id,
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        )
        do {
            try await center.add(request)
        } catch {
            return false
        }
        scheduled[id] = at
        persist()
        return true
    }

    /// Forgets the reminder and removes its pending notification, if any.
    func cancel(id: String) {
        center.removePendingNotificationRequests(withIdentifiers: [id])
        scheduled.removeValue(forKey: id)
        persist()
    }

    /// Whether a reminder with this id still waits for its date. Entries whose
    /// date has passed are pruned before answering.
    func isScheduled(id: String) -> Bool {
        pruneExpired(now: Date())
        return scheduled[id] != nil
    }

    // MARK: - Permission and housekeeping

    /// Asks for alert + sound once and caches the answer. The incident toggle
    /// (spec S14) calls it while turning on, so denial surfaces at the switch.
    @discardableResult
    func ensurePermissionGranted() async -> Bool {
        if let permissionGranted { return permissionGranted }
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        permissionGranted = granted
        return granted
    }

    /// Cancels every pending notification whose identifier starts with
    /// `prefix`: the incident toggle cleans its alerts on turning off.
    func cancelPendingNotifications(withPrefix prefix: String) async {
        let ids = await center.pendingNotificationRequests()
            .map(\.identifier)
            .filter { $0.hasPrefix(prefix) }
        guard !ids.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: ids)
        for id in ids { scheduled.removeValue(forKey: id) }
        persist()
    }

    // MARK: - Persistence

    private func loadScheduled() {
        guard let data = defaults.data(forKey: Self.storageKey),
              let stored = try? JSONDecoder().decode([String: TimeInterval].self, from: data)
        else { return }
        scheduled = stored.mapValues { Date(timeIntervalSince1970: $0) }
    }

    private func persist() {
        let encoded = scheduled.mapValues { $0.timeIntervalSince1970 }
        guard let data = try? JSONEncoder().encode(encoded) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    private func pruneExpired(now: Date) {
        let expired = scheduled.filter { $0.value <= now }.map(\.key)
        guard !expired.isEmpty else { return }
        for id in expired { scheduled.removeValue(forKey: id) }
        persist()
    }
}

/// Foreground presentation of reminders (spec S13): every alert arrives as a
/// banner with its sound, even while the app is open.
final class NotificationBannerDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
