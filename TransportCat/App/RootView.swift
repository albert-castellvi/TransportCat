import SwiftUI

/// Root tab navigation: live map, line diagram, service alerts and Explora.
@MainActor
struct RootView: View {
    @StateObject private var app = AppModel.shared
    /// Metro, bus, FGC or the global mode (specs S1, S6, S8). The same key the
    /// bottom accessory's mode menu writes, so picking a mode anywhere — menu,
    /// map or Parades screen — switches all of them.
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
            MapScreen(
                isActive: mode == .metro,
                onLocate: openNearby
            )
            .modifier(RetainedMode(isActive: mode == .metro))
            BusMapScreen(
                isActive: mode == .bus,
                onLocate: openNearby
            )
            .modifier(RetainedMode(isActive: mode == .bus))
            FGCMapScreen(onLocate: openNearby)
                .modifier(RetainedMode(isActive: mode == .fgc))
            GlobalMapScreen(
                isActive: mode == .global,
                onLocate: openNearby
            )
            .modifier(RetainedMode(isActive: mode == .global))
        }
    }

    /// The location button's extra behavior (spec S13, decision L8): after
    /// centring on the rider, the map screens open the "A prop teu" sheet
    /// through the router flag the sheet is bound to.
    private func openNearby() {
        AppRouter.shared.isNearbyPresented = true
    }

    var body: some View {
        // The visible tab is the router's (spec S5): `AppRouter.open` switches
        // to the map, and a tab tap writes back, so both stay in sync. iOS 26
        // Tab API (spec S5): one `Tab` per tab, selection values typed like
        // `router.selectedTab`, and the search role hosting Explora.
        @Bindable var router = AppRouter.shared
        TabView(selection: $router.selectedTab) {
            Tab("Mapa", image: "tab-map", value: AppTab.map) {
                mapModes
                    // Cutting between the four modes would be harsh, so the
                    // screens fade into each other instead (polish pass),
                    // nothing when Reduce Motion is on. The fade is the
                    // opacity of the layers below: no screen enters or leaves
                    // any more (spec S12).
                    .animation(AppMotion.smooth(duration: 0.25, reduceMotion: reduceMotion), value: mode)
                    // Spec S13 (mockup `V6Nearby`): the "A prop teu" sheet,
                    // opened by the maps' location buttons and the quick
                    // action. Bound to the router flag, so closing the sheet
                    // writes it back and the buttons unfill themselves. The
                    // list is injected its `AppModel` explicitly (it reads it
                    // through `@EnvironmentObject`).
                    .sheet(isPresented: $router.isNearbyPresented) {
                        NearbySheet()
                            .environmentObject(app)
                            // Medium leaves the map visible behind; large
                            // gives the list the whole height (spec S13).
                            .presentationDetents([.medium, .large])
                    }
                    // The sheet belongs to the map tab only: leaving the tab
                    // dismisses it instead of floating it over another tab.
                    .onChange(of: router.selectedTab) { _, newTab in
                        guard newTab != .map else { return }
                        AppRouter.shared.isNearbyPresented = false
                    }
            }
            // Renamed from "Xarxa" when the bus mode arrived: the tab now
            // shows the lines of whichever mode is on (spec S1). The v2
            // redesign renames it again to Parades (spec S5, decision L6).
            Tab("Parades", image: "tab-network", value: AppTab.lines) {
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
            }
            Tab("Avisos", image: "tab-alert", value: AppTab.alerts) {
                AlertsScreen()
            }
            // The fourth tab (spec S12): search, favorites and nearby places,
            // moved into the tab bar's own search role for the v2 redesign.
            Tab("Explora", systemImage: "magnifyingglass", value: AppTab.explore, role: .search) {
                ExploreScreen()
            }
        }
        // Spec S4: the bottom accessory above the tab bar, with the mode menu
        // and the context control of the mode on screen. It reads only shared
        // state and static catalog data, so showing it on every tab adds no
        // poller and never duplicates one.
        // #90: the accessory only acts on Mapa and Parades — over Avisos,
        // Explora and the planner it floats over content it cannot change —
        // so the tab bar hosts it only there.
        .modifier(ModeAccessory(
            isShown: router.selectedTab == .map || router.selectedTab == .lines,
            app: app
        ))
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
        // open: the map and Parades need them without a visit to Avisos (S1).
        // The connectivity monitor starts alongside it (S21): it exists to
        // gate the offline behaviors, nothing more.
        .task {
            // The connectivity monitor starts alongside the alerts poll: the
            // status capsule reads its `isOnline` to switch to the offline
            // wording the banner used to carry (spec S2 of the redesign).
            ConnectivityMonitor.shared.start()
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

/// Hosts the bottom accessory only where it acts (#90). The system modifier
/// that hides the accessory slot exists from iOS 26.1; on 26.0 the slot gets
/// empty content instead.
private struct ModeAccessory: ViewModifier {
    let isShown: Bool
    let app: AppModel

    func body(content: Content) -> some View {
        if #available(iOS 26.1, *) {
            content.tabViewBottomAccessory(isEnabled: isShown) {
                accessory
            }
        } else {
            content.tabViewBottomAccessory {
                if isShown {
                    accessory
                }
            }
        }
    }

    /// Injected explicitly: the accessory is hosted by the tab bar, and its
    /// metro chip reads `AppModel` through `@EnvironmentObject`.
    private var accessory: some View {
        BottomAccessory()
            .environmentObject(app)
    }
}
