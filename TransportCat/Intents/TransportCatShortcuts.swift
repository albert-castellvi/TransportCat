import AppIntents

/// Catalan invocation phrases (spec S15). Every phrase contains the
/// application name, as App Intents requires; the third one references the
/// intent's `place` parameter, so Shortcuts asks for the station or stop when
/// the caller does not name one.
struct TransportCatShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: NextArrivalsIntent(),
            phrases: [
                "Propers trens a \(.applicationName)",
                "Quan passa el bus amb \(.applicationName)",
                "Properes arribades a \(\.$place) amb \(.applicationName)",
            ],
            shortTitle: "Properes arribades",
            systemImageName: "tram.fill"
        )
    }
}
