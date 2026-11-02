import SwiftUI

/// Root tab navigation: live map, line diagram and service alerts.
struct RootView: View {
    @StateObject private var app = AppModel.shared
    /// Metro, bus or FGC (specs S1, S6). The same key the `ModeSelector` chips
    /// write, so picking a mode on one tab switches both of them.
    @AppStorage("appMode") private var modeRaw = AppMode.metro.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var mode: AppMode {
        AppMode(rawValue: modeRaw) ?? .metro
    }

    var body: some View {
        TabView {
            Group {
                switch mode {
                case .metro:
                    MapScreen()
                        .transition(.opacity)
                case .bus:
                    BusMapScreen()
                        .transition(.opacity)
                case .fgc:
                    FGCMapScreen()
                        .transition(.opacity)
                }
            }
            // Cutting between the three modes would be harsh, so the screens
            // fade into each other instead (polish pass), nothing when Reduce
            // Motion is on.
            .animation(AppMotion.smooth(duration: 0.25, reduceMotion: reduceMotion), value: mode)
            .tabItem {
                Label("Mapa", image: "tab-map")
            }
            // Renamed from "Xarxa" when the bus mode arrived: the tab now
            // shows the lines of whichever mode is on (spec S1).
            Group {
                switch mode {
                case .metro:
                    DiagramScreen()
                        .transition(.opacity)
                case .bus:
                    BusDiagramScreen()
                        .transition(.opacity)
                case .fgc:
                    FGCLinesScreen()
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
        // The one FGC poller (spec S6): `run()` loads the topology once and
        // then polls the trains every 30 s for both FGC screens. Keying the
        // task on the mode cancels it the moment the rider leaves FGC, so
        // there is never a second loop, and re-entering the mode resumes on
        // the state that is already loaded.
        .task(id: mode) {
            guard mode == .fgc else { return }
            await FGCNetworkState.shared.run()
        }
    }
}
