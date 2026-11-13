import AppIntents

/// Catalan invocation phrases (spec S15). Every phrase contains the
/// application name, as App Intents requires. The first two name no place, so
/// Siri runs them for the rider's defaults; the third carries the intent's
/// `place` parameter, so Shortcuts asks which station or stop when the caller
/// does not name one.
struct TransportCatShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: NextArrivalsIntent(),
            phrases: [
                "Properes arribades amb \(.applicationName)",
                "Quant passa el proper tren amb \(.applicationName)",
                "Quan passa el bus a \(\.$place) amb \(.applicationName)",
            ],
            shortTitle: "Properes arribades",
            systemImageName: "tram.fill"
        )
    }
}
