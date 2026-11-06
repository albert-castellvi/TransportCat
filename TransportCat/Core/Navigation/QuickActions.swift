import Foundation

/// Home-screen quick actions (spec S14, mockup `V6QuickAction`).
///
/// Foundation-only rules, testable without a scene: the shortcut item type
/// strings, the mapping from a type to the route the app applies, and the
/// title pieces of the "last line viewed" item. UIKit builds the items and
/// applies the routes (`SceneDelegate`); nothing here touches UIKit or
/// SwiftUI, so the rules stay pure.

/// The route a quick action asks for, decoupled from UIKit and the router.
enum QuickActionRoute: Equatable {
    /// Open the "A prop teu" sheet over the map (spec S13).
    case nearby
    /// Reopen the last viewed line on its operator's map.
    case lastLine
    /// The service alerts tab.
    case alerts
    /// The Explora tab (search a stop).
    case searchStop
}

/// The `UIApplicationShortcutItem.type` strings, one per quick action.
enum QuickActionType {
    static let nearby = "cat.transport.app.qa.nearby"
    static let lastLine = "cat.transport.app.qa.lastline"
    static let alerts = "cat.transport.app.qa.alerts"
    static let searchStop = "cat.transport.app.qa.searchstop"

    static let all = [nearby, lastLine, alerts, searchStop]
}

enum QuickActions {
    /// The route of a shortcut item type, or nil for an unknown one.
    static func route(forType type: String) -> QuickActionRoute? {
        switch type {
        case QuickActionType.nearby: return .nearby
        case QuickActionType.lastLine: return .lastLine
        case QuickActionType.alerts: return .alerts
        case QuickActionType.searchStop: return .searchStop
        default: return nil
        }
    }

    /// Title of the "last line viewed" item: "L2 · Paral·lel – Badalona" when
    /// the line's descriptive name is known, else just its display code.
    static func lastLineTitle(displayCode: String, detail: String?) -> String {
        guard let detail, !detail.isEmpty else { return displayCode }
        return "\(displayCode) · \(detail)"
    }

    /// The badge code a metro line shows: "L2" for the stored TMB code "2",
    /// or the stored code back when it names no metro line.
    static func metroDisplayCode(lineCode: String) -> String {
        MetroLine.line(forCode: lineCode)?.displayName ?? lineCode
    }

    /// The destination of the "last line" route for the persisted mode and
    /// line, or nil when the mode has no line to reopen (global, unknown).
    ///
    /// `AppRouter.open` consumes it: it persists the mode and line again and
    /// lands on that operator's map.
    static func lastLineDestination(mode: String, lineCode: String) -> Destination? {
        switch mode {
        case AppModeCode.metro, AppModeCode.bus, AppModeCode.fgc:
            return .line(operator: mode, code: lineCode)
        default:
            return nil
        }
    }
}
