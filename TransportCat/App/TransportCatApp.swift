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
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
