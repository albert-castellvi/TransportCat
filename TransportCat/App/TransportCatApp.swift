import Sentry
import SwiftUI

@main
struct TransportCatApp: App {
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
            RootView()
        }
    }
}
