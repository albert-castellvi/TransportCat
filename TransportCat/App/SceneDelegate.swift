import UIKit

/// Scene delegate for the home-screen quick actions (spec S14).
///
/// With the SwiftUI app lifecycle this delegate has exactly three jobs, all
/// quick-action plumbing, and keeps every scene handling the existing
/// `AppDelegate` already does:
///
/// - a cold launch through a shortcut arrives in
///   `scene(_:willConnectTo:options:)` as `connectionOptions.shortcutItem`;
/// - one chosen while the app runs arrives in
///   `windowScene(_:performActionFor:completionHandler:)`;
/// - the items are rebuilt every time the scene becomes active, because the
///   "last line viewed" may have changed since the previous build.
///
/// The routing rules themselves live in the pure `QuickActions` helper; this
/// type only carries the UIKit shapes.
final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        // Cold launch through a shortcut: routing here tells the system the
        // item was handled, so it does not call `performActionFor` for it
        // again. `AppRouter.shared` is a singleton, so the routed state is
        // already in place when SwiftUI builds `RootView`.
        guard let item = connectionOptions.shortcutItem else { return }
        MainActor.assumeIsolated {
            Self.apply(item)
        }
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        // Rebuild on every activation: the last viewed line is read from
        // storage, so the home-screen entry always matches what the rider
        // last saw. Launch runs on the main thread; the router and the
        // stores below need the isolation.
        MainActor.assumeIsolated {
            UIApplication.shared.shortcutItems = Self.makeItems()
        }
    }

    func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        MainActor.assumeIsolated {
            Self.apply(shortcutItem)
            completionHandler(true)
        }
    }

    // MARK: - Items

    /// The four quick actions (spec S14, mockup `V6QuickAction`): "A prop
    /// teu", the last viewed line, alerts and stop search. The line item is
    /// omitted until the rider has actually viewed one.
    @MainActor
    static func makeItems() -> [UIApplicationShortcutItem] {
        var items: [UIApplicationShortcutItem] = [
            UIApplicationShortcutItem(
                type: QuickActionType.nearby,
                localizedTitle: String(localized: "A prop teu"),
                localizedSubtitle: String(localized: "Properes arribades on ets"),
                icon: UIApplicationShortcutIcon(systemImageName: "location.fill"),
                userInfo: nil
            )
        ]
        if let lineItem = makeLastLineItem() {
            items.append(lineItem)
        }
        items.append(
            contentsOf: [
                UIApplicationShortcutItem(
                    type: QuickActionType.alerts,
                    localizedTitle: String(localized: "Avisos"),
                    localizedSubtitle: nil,
                    icon: UIApplicationShortcutIcon(systemImageName: "exclamationmark.triangle"),
                    userInfo: nil
                ),
                UIApplicationShortcutItem(
                    type: QuickActionType.searchStop,
                    localizedTitle: String(localized: "Cercar una parada"),
                    localizedSubtitle: nil,
                    icon: UIApplicationShortcutIcon(systemImageName: "magnifyingglass"),
                    userInfo: nil
                )
            ]
        )
        return items
    }

    /// The "last line viewed" item, built from the persisted mode and line
    /// keys (`appMode`, `metroSelectedLine`, `busSelectedLine`,
    /// `fgcSelectedLine`). Nil when no line was ever viewed or the mode has
    /// no line (global). The mode and code travel in `userInfo` because the
    /// home screen shows the item captured when it was built: after a line
    /// change the delivered item must still route to the line it displays.
    ///
    /// #44: the mode comes from `AppRouter.effectiveMode`, not from `appMode`
    /// alone — that key is only written by the router and the mode menu, so a
    /// fresh install that browsed lines in the default metro mode has a line
    /// selected and no mode stored, and used to lose the item.
    @MainActor
    private static func makeLastLineItem() -> UIApplicationShortcutItem? {
        let defaults = UserDefaults.standard
        let mode = AppRouter.effectiveMode(defaults: defaults)

        let storedCode: String?
        switch mode {
        case AppModeCode.metro:
            storedCode = defaults.string(forKey: AppRouter.metroSelectedLineKey)
        case AppModeCode.fgc:
            storedCode = defaults.string(forKey: AppRouter.fgcSelectedLineKey)
        case AppModeCode.bus:
            // The bus selection is stored as the numeric `CODI_LINIA`.
            storedCode = (defaults.object(forKey: AppRouter.busSelectedLineKey) as? Int)
                .map(String.init)
        default:
            return nil
        }
        guard let storedCode, !storedCode.isEmpty else { return nil }

        // Badge code and descriptive name per operator. Each detail source is
        // optional: a cold cache simply shows the plain line code.
        let displayCode: String
        let detail: String?
        switch mode {
        case AppModeCode.metro:
            displayCode = QuickActions.metroDisplayCode(lineCode: storedCode)
            detail = MetroLineTermini.cachedTermini(lineCode: storedCode)
        case AppModeCode.fgc:
            displayCode = storedCode
            detail = FGCNetworkState.shared.lines.first { $0.code == storedCode }?.name
        case AppModeCode.bus:
            let line = BusCatalogStore.shared.lines.first { String($0.code) == storedCode }
            displayCode = line?.name ?? storedCode
            detail = line?.description
        default:
            return nil
        }

        return UIApplicationShortcutItem(
            type: QuickActionType.lastLine,
            localizedTitle: QuickActions.lastLineTitle(displayCode: displayCode, detail: detail),
            localizedSubtitle: String(localized: "L'última línia que has mirat"),
            icon: nil,
            userInfo: [
                "mode": mode as NSString,
                "code": storedCode as NSString
            ]
        )
    }

    /// Applies a shortcut item: the pure route mapping, then the router.
    @MainActor
    static func apply(_ item: UIApplicationShortcutItem) {
        guard let route = QuickActions.route(forType: item.type) else { return }
        switch route {
        case .nearby:
            // Tab first, then the flag: the sheet is attached to the map
            // tab, and a tab switch dismisses it (spec S13).
            AppRouter.shared.selectedTab = .map
            AppRouter.shared.isNearbyPresented = true
        case .lastLine:
            guard let mode = item.userInfo?["mode"] as? String,
                  let code = item.userInfo?["code"] as? String,
                  let destination = QuickActions.lastLineDestination(mode: mode, lineCode: code)
            else { return }
            AppRouter.shared.open(destination)
        case .alerts:
            AppRouter.shared.selectedTab = .alerts
        case .searchStop:
            AppRouter.shared.selectedTab = .explore
        }
    }
}
