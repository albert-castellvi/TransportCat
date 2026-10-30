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
    }
}
