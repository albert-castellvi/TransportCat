import SwiftUI

/// Root tab navigation: live map, line diagram and service alerts.
struct RootView: View {
    @StateObject private var app = AppModel.shared
    /// Metro or bus (spec S1). The same key the `ModeSelector` chips write, so
    /// picking a mode on one tab switches both of them.
    @AppStorage("appMode") private var modeRaw = AppMode.metro.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var mode: AppMode {
        AppMode(rawValue: modeRaw) ?? .metro
    }

    var body: some View {
        TabView {
            Group {
                if mode == .bus {
                    BusMapScreen()
                        .transition(.opacity)
                } else {
                    MapScreen()
                        .transition(.opacity)
                }
            }
            // Metro <-> bus is a cut today: fade the two screens into each
            // other instead (polish pass), nothing when Reduce Motion is on.
            .animation(AppMotion.smooth(duration: 0.25, reduceMotion: reduceMotion), value: mode)
            .tabItem {
                Label("Mapa", image: "tab-map")
            }
            // Renamed from "Xarxa" when the bus mode arrived: the tab now
            // shows the lines of whichever mode is on (spec S1).
            Group {
                if mode == .bus {
                    BusDiagramScreen()
                        .transition(.opacity)
                } else {
                    DiagramScreen()
                        .transition(.opacity)
                }
            }
            .animation(AppMotion.smooth(duration: 0.25, reduceMotion: reduceMotion), value: mode)
            .tabItem {
                Label("Línies", image: "tab-network")
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
