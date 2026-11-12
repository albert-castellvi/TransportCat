import Foundation

#if canImport(UserNotifications)
import UserNotifications
#endif
#if canImport(BackgroundTasks)
import BackgroundTasks
#endif

/// Incident alerts for the rider's favorite lines (spec S14): diffs the metro
/// and bus alert feeds against the favorites, notifies each new alert id once
/// and persists the seen ids. It also owns the `cat.transport.app.alerts-refresh`
/// background task, which is best effort — iOS decides when it runs.
///
/// The notification and background-task legs are framework-gated so the pure
/// rules compile — and their tests run — where those frameworks are absent.
@MainActor
final class IncidentWatcher {
    static let shared = IncidentWatcher()

    /// BGTaskScheduler identifier; mirrored in `BGTaskSchedulerPermittedIdentifiers`.
    nonisolated static let taskIdentifier = "cat.transport.app.alerts-refresh"
    /// Key of the AlertsScreen switch (contract S14), off by default.
    nonisolated static let enabledKey = "incidentAlertsEnabled"
    /// Key holding the alert ids already notified.
    nonisolated static let seenKey = "seenAlertIds.v1"
    /// Prefix of the notification identifiers, so turning the toggle off can
    /// cancel exactly the incident alerts and keep arrival reminders.
    nonisolated static let notificationIDPrefix = "incident:"
    /// Contract: the background refresh is planned at least 15 minutes apart.
    nonisolated static let refreshInterval: TimeInterval = 15 * 60
    /// Seen ids are a rolling window; the oldest entries are evicted first.
    nonisolated static let maxSeenIDs = 400

    private let defaults: UserDefaults
    /// Alert ids already notified, oldest first.
    private(set) var seenIDs: [String]
    /// Last lists seen from the app's 60 s pollers, kept so a metro refresh and
    /// a bus refresh arriving seconds apart are evaluated with both feeds.
    private var lastMetro: [ServiceAlert] = []
    private var lastBus: [ServiceAlert] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        seenIDs = Self.storedSeenIDs(defaults)
    }

    /// The toggle state (contract S14 default false).
    var isEnabled: Bool {
        get { defaults.bool(forKey: Self.enabledKey) }
        set { defaults.set(newValue, forKey: Self.enabledKey) }
    }

    // MARK: - Pure rules

    /// The alerts to notify: current alerts touching a favorite line, unseen,
    /// each id once, in feed order.
    nonisolated static func newAlerts(
        current: [ServiceAlert],
        favoriteLines: Set<String>,
        seen: Set<String>
    ) -> [ServiceAlert] {
        var emitted: Set<String> = []
        var result: [ServiceAlert] = []
        for alert in current where !seen.contains(alert.id) && !emitted.contains(alert.id) {
            guard alert.lineCodes.contains(where: favoriteLines.contains) else { continue }
            emitted.insert(alert.id)
            result.append(alert)
        }
        return result
    }

    /// The line codes the rider follows: metro favorites as stored plus the
    /// API code of any display name ("L9N" -> "94"), plus the numeric bus
    /// favorites. FGC favorites stay out: the watched feeds are metro and bus.
    nonisolated static func favoriteLineCodes(metro: [String], bus: [Int]) -> Set<String> {
        var codes = Set(metro)
        for code in metro {
            if let line = MetroLine.allLines.first(where: {
                $0.displayName.caseInsensitiveCompare(code) == .orderedSame
            }) {
                codes.insert(line.code)
            }
        }
        codes.formUnion(bus.map(String.init))
        return codes
    }

    /// Notification title naming the affected line (contract S14). `busNames`
    /// maps numeric bus codes to commercial names ("212" -> "H12").
    nonisolated static func title(
        for alert: ServiceAlert,
        isBus: Bool,
        busNames: [String: String]
    ) -> String {
        guard let code = alert.lineCodes.first else { return "Incidència a la xarxa" }
        if isBus { return "Incidència a \(busNames[code] ?? code)" }
        let line = MetroLine.line(forCode: code)?.displayName ?? code
        return "Incidència a \(line)"
    }

    /// Adds an id to the rolling seen window; a repeat changes nothing and the
    /// oldest ids fall out beyond `cap`.
    nonisolated static func appendingSeen(
        _ seen: [String],
        id: String,
        cap: Int = maxSeenIDs
    ) -> [String] {
        guard !seen.contains(id) else { return seen }
        var grown = seen
        grown.append(id)
        if grown.count > cap {
            grown.removeFirst(grown.count - cap)
        }
        return grown
    }

    /// The persisted seen ids; anything that is not a string array reads empty.
    nonisolated static func storedSeenIDs(_ defaults: UserDefaults) -> [String] {
        defaults.stringArray(forKey: seenKey) ?? []
    }

    // MARK: - Foreground trigger

    #if canImport(UserNotifications)

    /// Feeds the latest alert lists into the watcher (called by the app's
    /// observers on every 60 s poll). Without favorites or with the toggle off
    /// nothing is scheduled.
    func handleAlertsUpdate(metro: [ServiceAlert]? = nil, bus: [ServiceAlert]? = nil) {
        if let metro { lastMetro = metro }
        if let bus { lastBus = bus }
        guard isEnabled else { return }
        let lists = (lastMetro, lastBus)
        Task { await process(metro: lists.0, bus: lists.1) }
    }

    /// Notifies the new alerts of both feeds; returns how many were notified.
    @discardableResult
    func process(metro: [ServiceAlert], bus: [ServiceAlert]) async -> Int {
        guard isEnabled else { return 0 }
        let favorites = Self.favoriteLineCodes(
            metro: FavoritesStore.shared.favoriteLines
                .filter { $0.operator == FavoriteLine.metro }
                .map(\.code),
            bus: BusCatalogStore.shared.favorites
        )
        guard !favorites.isEmpty else { return 0 }

        var notified = 0
        for alert in Self.newAlerts(current: metro, favoriteLines: favorites, seen: Set(seenIDs)) {
            if await notify(alert, isBus: false, busNames: [:]) { notified += 1 }
        }
        let busNames = Dictionary(
            uniqueKeysWithValues: BusCatalogStore.shared.lines.map { (String($0.code), $0.name) }
        )
        for alert in Self.newAlerts(current: bus, favoriteLines: favorites, seen: Set(seenIDs)) {
            if await notify(alert, isBus: true, busNames: busNames) { notified += 1 }
        }
        return notified
    }

    /// Schedules the alert as an immediate notification (the foreground banner
    /// delegate shows it while the app is open) and marks it seen either way:
    /// a denied permission must not retry the same alert on every poll.
    private func notify(_ alert: ServiceAlert, isBus: Bool, busNames: [String: String]) async -> Bool {
        let body = AlertText.cleaned(alert.text)
            ?? AlertText.effect(for: alert)
            ?? "Obre TransportCat per saber-ne més."
        // Ask first, then take the date: the grant can outlast the one second
        // of lead, which left the trigger in the past.
        let granted = await ArrivalReminder.shared.ensurePermissionGranted()
        // One second ahead: `schedule` refuses a date already past, and a
        // zero-date trigger is not guaranteed to fire immediately.
        var scheduled = false
        if granted {
            scheduled = await ArrivalReminder.shared.schedule(
                id: Self.notificationIDPrefix + alert.id,
                title: Self.title(for: alert, isBus: isBus, busNames: busNames),
                body: body,
                at: Date().addingTimeInterval(1)
            )
        }
        seenIDs = Self.appendingSeen(seenIDs, id: alert.id)
        defaults.set(seenIDs, forKey: Self.seenKey)
        return scheduled
    }

    // MARK: - Background refresh

    /// The `BGAppRefreshTask` body: fetches both alert feeds with a bundle
    /// client, runs the same diff, and always reschedules the next window.
    func runBackgroundRefresh() async -> Bool {
        defer { Self.scheduleNextRefresh() }
        guard isEnabled, let client = try? TMBClient.fromBundle() else { return false }
        let metro = try? await client.alerts()
        let bus = try? await client.busAlerts()
        guard metro != nil || bus != nil else { return false }
        await process(metro: metro ?? [], bus: bus ?? [])
        return true
    }

    #endif

    #if canImport(BackgroundTasks)

    /// Registers the background refresh; call once at launch, before the app
    /// finishes launching. The handler plans the next window before doing any
    /// work, so a killed refresh still leaves the schedule alive.
    nonisolated static func registerBackgroundTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            scheduleNextRefresh()
            let completion = BGTaskCompletionGuard(task: refresh)
            Task {
                let ok = await IncidentWatcher.shared.runBackgroundRefresh()
                completion.finish(success: ok)
            }
            refresh.expirationHandler = {
                completion.finish(success: false)
            }
        }
    }

    /// Plans the next refresh window (at least `refreshInterval` away).
    nonisolated static func scheduleNextRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: refreshInterval)
        try? BGTaskScheduler.shared.submit(request)
    }

    #endif
}

#if canImport(BackgroundTasks)
/// Calls `setTaskCompleted(success:)` at most once: the work task and the
/// expiration handler race, and completing twice raises.
private final class BGTaskCompletionGuard: @unchecked Sendable {
    private let task: BGAppRefreshTask
    private let lock = NSLock()
    private var finished = false

    init(task: BGAppRefreshTask) {
        self.task = task
    }

    func finish(success: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        task.setTaskCompleted(success: success)
    }
}
#endif
