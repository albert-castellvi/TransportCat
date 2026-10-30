import SwiftUI

/// Root tab navigation: live map, line diagram and service alerts.
struct RootView: View {
    @StateObject private var app = AppModel.shared

    var body: some View {
        TabView {
            MapScreen()
                .tabItem {
                    Label("Mapa", image: "tab-map")
                }
            DiagramScreen()
                .tabItem {
                    Label("Xarxa", image: "tab-network")
                }
            AlertsScreen()
                .tabItem {
                    Label("Avisos", image: "tab-alert")
                }
        }
        .environmentObject(app)
        // Incidents load at launch and refresh every minute, whichever tab is
        // open: the map and Xarxa need them without a visit to Avisos (S1).
        .task {
            await app.startAlertsPolling()
        }
    }
}
