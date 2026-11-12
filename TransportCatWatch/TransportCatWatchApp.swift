import SwiftUI

/// TransportCat for Apple Watch (spec S22): the favorite places synced from
/// the phone, their next arrivals, and a search by name.
@main
@MainActor
struct TransportCatWatchApp: App {
    /// #79: activation can fail (for example before the phone pairs), so the
    /// receiver is asked to retry every time the watch app comes back to the
    /// foreground.
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environment(WatchFavoritesStore.shared)
                .environment(WatchSessionReceiver.shared)
                // Activate and read the application context right at launch;
                // the receiver keeps listening after that.
                .task {
                    await MainActor.run { WatchSessionReceiver.shared.activate() }
                }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    WatchSessionReceiver.shared.activate()
                }
        }
    }
}
