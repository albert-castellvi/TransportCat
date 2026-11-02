import SwiftUI

/// Root tab navigation: live map, line diagram, service alerts and Explora.
struct RootView: View {
    @StateObject private var app = AppModel.shared
    /// Metro, bus, FGC or the global mode (specs S1, S6, S8). The same key the
    /// `ModeSelector` chips write, so picking a mode on one tab switches both
    /// of them.
    @AppStorage("appMode") private var modeRaw = AppMode.metro.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var mode: AppMode {
        AppMode(rawValue: modeRaw) ?? .metro
    }

    var body: some View {
        // The visible tab is the router's (spec S5): `AppRouter.open` switches
        // to the map, and a tab tap writes back, so both stay in sync.
        @Bindable var router = AppRouter.shared
        TabView(selection: $router.selectedTab) {
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
                case .global:
                    GlobalMapScreen()
                        .transition(.opacity)
                }
            }
            // Cutting between the four modes would be harsh, so the screens
            // fade into each other instead (polish pass), nothing when Reduce
            // Motion is on.
            .animation(AppMotion.smooth(duration: 0.25, reduceMotion: reduceMotion), value: mode)
            .tabItem {
                Label("Mapa", image: "tab-map")
            }
            .tag(AppTab.map)
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
                case .global:
                    GlobalLinesScreen()
                        .transition(.opacity)
                }
            }
            .animation(AppMotion.smooth(duration: 0.25, reduceMotion: reduceMotion), value: mode)
            .tabItem {
                Label("Línies", image: "tab-network")
            }
            .tag(AppTab.lines)
            AlertsScreen()
                .tabItem {
                    Label("Avisos", image: "tab-alert")
                }
                .tag(AppTab.alerts)
            // The fourth tab (spec S12): search, favorites and nearby places.
            ExploreScreen()
                .tabItem {
                    Label("Explora", systemImage: "magnifyingglass")
                }
                .tag(AppTab.explore)
        }
        .environmentObject(app)
        // Incidents load at launch and refresh every minute, whichever tab is
        // open: the map and Xarxa need them without a visit to Avisos (S1).
        .task {
            await app.startAlertsPolling()
        }
        // The one FGC poller (spec S6): `run()` loads the topology once and
        // then polls the trains every 30 s for both FGC screens — and for the
        // global mode, whose map and lines list draw FGC too (S8). Keying the
        // task on the mode cancels it the moment the rider leaves FGC and
        // global alike, so there is still exactly one poller, and re-entering
        // a mode resumes on the state that is already loaded.
        .task(id: mode) {
            guard mode == .fgc || mode == .global else { return }
            await FGCNetworkState.shared.run()
        }
    }
}
