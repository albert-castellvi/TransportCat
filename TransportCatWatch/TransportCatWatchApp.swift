import SwiftUI

/// TransportCat for Apple Watch (spec S22): the favorite places synced from
/// the phone, their next arrivals, and a search by name.
@main
@MainActor
struct TransportCatWatchApp: App {
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
        }
    }
}
