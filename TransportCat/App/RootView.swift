import SwiftUI

/// Root tab navigation: live map, line diagram, service alerts and Explora.
@MainActor
struct RootView: View {
    @StateObject private var app = AppModel.shared
    /// Network path state driving the offline banner (spec S21).
    @State private var connectivity = ConnectivityMonitor.shared
    /// Metro, bus, FGC or the global mode (specs S1, S6, S8). The same key the
    /// `ModeSelector` chips write, so picking a mode on one tab switches both
    /// of them.
    @AppStorage("appMode") private var modeRaw = AppMode.metro.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    private var mode: AppMode {
        AppMode(rawValue: modeRaw) ?? .metro
    }

    /// The four modes of the Mapa tab, all of them alive at once (spec S12).
    ///
    /// They used to be swapped by a `switch`, which destroyed the outgoing
    /// screen together with its `MKMapView`, its tiles and its `@State` — the
    /// frozen frame and spinner the 2026-11-03 recording caught on FGC → bus.
    /// Hosting them in a `ZStack` keeps all of that warm, so a mode switch is
    /// an opacity change instead of a rebuild.
    ///
    /// Only the active mode is drawn, takes taps and is announced; the others
    /// stay mounted at zero opacity with no hit testing and hidden from
    /// VoiceOver, so two maps are never interactive at once. Each screen is
    /// told through `isActive` to stop loading and polling while it is off
    /// screen (spec S13).
    private var mapModes: some View {
        ZStack {
            MapScreen(isActive: mode == .metro)
                .modifier(RetainedMode(isActive: mode == .metro))
            BusMapScreen(isActive: mode == .bus)
                .modifier(RetainedMode(isActive: mode == .bus))
            FGCMapScreen()
                .modifier(RetainedMode(isActive: mode == .fgc))
            GlobalMapScreen(isActive: mode == .global)
                .modifier(RetainedMode(isActive: mode == .global))
        }
    }

    var body: some View {
        // The visible tab is the router's (spec S5): `AppRouter.open` switches
        // to the map, and a tab tap writes back, so both stay in sync.
        @Bindable var router = AppRouter.shared
        TabView(selection: $router.selectedTab) {
            mapModes
                // Cutting between the four modes would be harsh, so the screens
                // fade into each other instead (polish pass), nothing when
                // Reduce Motion is on. The fade is the opacity of the layers
                // below: no screen enters or leaves any more (spec S12).
                .animation(AppMotion.smooth(duration: 0.25, reduceMotion: reduceMotion), value: mode)
            // Spec S21: while the device has no network path, a capsule at the
            // top of the Mapa tab says the lines and trains on screen come
            // from saved data and the timetable. TabView only draws the
            // selected tab, so the banner is never on another tab.
            .overlay(alignment: .top) {
                if !connectivity.isOnline {
                    OfflineBanner()
                }
            }
            .animation(AppMotion.smooth(reduceMotion: reduceMotion), value: connectivity.isOnline)
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
        .onAppear { syncFrameMonitoring() }
        .onDisappear {
            if PerfTelemetry.isEnabled { FrameMonitor.shared.end() }
        }
        .onChange(of: scenePhase) { _, _ in syncFrameMonitoring() }
        .onChange(of: router.selectedTab) { _, _ in syncFrameMonitoring() }
        .onChange(of: modeRaw) { _, newMode in
            guard PerfTelemetry.isEnabled else { return }
            syncFrameMonitoring()
            let trace = PerfTrace()
            trace.begin("ui.mode_switch", tags: [
                "mode": (AppMode(rawValue: newMode) ?? .metro).rawValue,
                "boundary": "next_display_link"
            ])
            // Switch observation to the next display opportunity; NOT tile
            // readiness, GPU presentation, or animation completion.
            trace.endOnNextFrame()
        }
        // Incidents load at launch and refresh every minute, whichever tab is
        // open: the map and Xarxa need them without a visit to Avisos (S1).
        // The connectivity monitor starts alongside it (S21): it exists to
        // gate the offline behaviors, nothing more.
        .task {
            connectivity.start()
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

    /// Root visibility is authoritative: retained offscreen maps cannot start sampling.
    private func syncFrameMonitoring() {
        guard PerfTelemetry.isEnabled else { return }
        if scenePhase == .active, AppRouter.shared.selectedTab == .map {
            FrameMonitor.shared.begin(mode: mode.rawValue)
        } else {
            FrameMonitor.shared.end()
        }
    }
}

/// Makes one of the four retained map screens the visible one (spec S12): the
/// active mode is drawn at full opacity, takes taps and is announced by
/// VoiceOver, while the others stay mounted but invisible, non-interactive and
/// silent. Keeping them mounted is the point — their `@State` and their
/// `MKMapView` survive the switch.
private struct RetainedMode: ViewModifier {
    let isActive: Bool

    func body(content: Content) -> some View {
        content
            .opacity(isActive ? 1 : 0)
            .allowsHitTesting(isActive)
            .accessibilityHidden(!isActive)
    }
}

/// The capsule the Mapa tab shows while the device is offline (spec S21):
/// saved topologies and theoretical timetables are what the map is drawing.
private struct OfflineBanner: View {
    var body: some View {
        Label("Sense connexió · dades desades i horaris teòrics", systemImage: "wifi.slash")
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.thinMaterial, in: Capsule())
            .padding(.top, 8)
            .transition(AppMotion.chipTransition)
    }
}
