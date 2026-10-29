import SwiftUI

/// Temporary root view. Replaced by the full tab navigation in the UI task.
struct RootView: View {
    var body: some View {
        TabView {
            Text("Mapa")
                .tabItem {
                    Label("Mapa", systemImage: "map")
                }
            Text("Xarxa")
                .tabItem {
                    Label("Xarxa", systemImage: "tram.fill")
                }
        }
    }
}
