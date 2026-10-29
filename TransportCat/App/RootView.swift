import SwiftUI

/// Root tab navigation: live map, line diagram and service alerts.
struct RootView: View {
    @StateObject private var app = AppModel.shared

    var body: some View {
        TabView {
            MapScreen()
                .tabItem {
                    Label("Mapa", systemImage: "map")
                }
            DiagramScreen()
                .tabItem {
                    Label("Xarxa", systemImage: "tram.fill")
                }
            AlertsScreen()
                .tabItem {
                    Label("Avisos", systemImage: "exclamationmark.triangle")
                }
        }
        .environmentObject(app)
    }
}
