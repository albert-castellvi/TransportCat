import Sentry
import SwiftUI

@main
struct TransportCatApp: App {
    /// Incident-alert plumbing without a SwiftUI equivalent (spec S14).
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Crash reporting is active only when a DSN is injected at build
        // time; local/unsigned builds run without Sentry.
        if let dsn = Bundle.main.infoDictionary?["SentryDSN"] as? String, !dsn.isEmpty {
            SentrySDK.start { options in
                options.dsn = dsn
                // Breadcrumbs of HTTP calls record the query string, which
                // holds the TMB credentials.
                options.enableNetworkBreadcrumbs = false
                options.beforeSend = { event in
                    event.exceptions?.forEach { $0.value = SecretRedactor.redact($0.value) }
                    return event
                }
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            // Spec S14: every 60 s alerts poll flows through the watcher,
            // which notifies the new alerts of the favorite lines once.
            RootView()
                .onReceive(AppModel.shared.$alerts) { alerts in
                    IncidentWatcher.shared.handleAlertsUpdate(metro: alerts)
                }
                .onReceive(AppModel.shared.$busAlerts) { busAlerts in
                    IncidentWatcher.shared.handleAlertsUpdate(bus: busAlerts)
                }
        }
    }
}

/// Launch-time registration for the arrival-reminder banner delegate and the
/// incident-alerts background refresh (specs S13, S14).
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Launch runs on the main thread; the actors below need the isolation.
        MainActor.assumeIsolated {
            // Creating the reminder installs its foreground delegate, so
            // notifications while the app is open show as banners (S13).
            _ = ArrivalReminder.shared
            IncidentWatcher.registerBackgroundTask()
            if IncidentWatcher.shared.isEnabled {
                IncidentWatcher.scheduleNextRefresh()
            }
        }
        return true
    }
}
