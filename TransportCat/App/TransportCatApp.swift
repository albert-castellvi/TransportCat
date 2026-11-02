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
            // Spec S22: the phone mirrors the favorite places to the watch.
            WatchFavoritesSyncView {
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
}

/// Keeps the Apple Watch in sync with the favorite places (spec S22).
///
/// A small view rather than a modifier on `RootView` because the favorites are
/// observed from SwiftUI: reading `FavoritesStore.shared.favoritePlaces` in
/// `body` is what makes this view re-evaluate, and therefore `onChange` fire,
/// when the rider stars or unstars a place.
private struct WatchFavoritesSyncView<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .task {
                // Activate the session and push the current list at launch.
                // The hop keeps the call valid whichever isolation SwiftUI
                // gives the task closure.
                #if canImport(WatchConnectivity)
                await MainActor.run {
                    WatchSync.shared.start(places: FavoritesStore.shared.favoritePlaces)
                }
                #endif
            }
            .onChange(of: FavoritesStore.shared.favoritePlaces) { _, places in
                #if canImport(WatchConnectivity)
                Task { @MainActor in WatchSync.shared.sync(places) }
                #endif
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
