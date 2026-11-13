import Foundation
import Observation

/// The four root tabs (spec S5). Raw values are stable because a later phase
/// may persist the selected tab.
enum AppTab: String, CaseIterable, Identifiable {
    case map
    case lines
    case alerts
    case explore

    var id: String { rawValue }
}

/// Persisted app-mode raw values, shared by `Destination` and `AppRouter`
/// without touching the SwiftUI `AppMode` (which lives in Features).
enum AppModeCode {
    static let metro = "metro"
    static let bus = "bus"
    static let fgc = "fgc"
    static let rodalies = "rodalies"
}

/// Where the app should take the rider next (spec S5).
///
/// `operator` is the persisted app mode: "metro", "bus", "fgc" or
/// "rodalies".
enum Destination: Hashable {
    case place(Place)
    /// `code` is the map's line code: metro "1", FGC "S1", bus "212" (the
    /// numeric `BusLine.code`, as the bus selection is stored as an Int).
    case line(operator: String, code: String)
    /// `lineCode` follows the same convention as `line`.
    case vehicle(operator: String, lineCode: String, vehicleID: String)

    /// "metro", "bus", "fgc" or "rodalies".
    var `operator`: String {
        switch self {
        case .place(let place):
            switch place.kind {
            case .metroStation: return AppModeCode.metro
            case .busStop: return AppModeCode.bus
            case .fgcStation: return AppModeCode.fgc
            case .rodaliesStation: return AppModeCode.rodalies
            }
        case .line(let `operator`, _): return `operator`
        case .vehicle(let `operator`, _, _): return `operator`
        }
    }
}

/// App-wide navigation intent (spec S5): which tab is visible and which place,
/// line or vehicle a screen should center on.
///
/// `open(_:)` writes the persisted mode and selected line before switching to
/// the map tab, so the map opens already on the right operator and line. The
/// screen that handles the focus calls `clearFocus()` (or `takeFocus()`) once it
/// has acted on it.
@MainActor
@Observable
final class AppRouter {
    static let shared = AppRouter()

    static let appModeKey = "appMode"
    static let metroSelectedLineKey = "metroSelectedLine"
    static let fgcSelectedLineKey = "fgcSelectedLine"
    /// Same key the Rodalies screens and the accessory's chip read.
    static let rodaliesSelectedLineKey = "rodaliesSelectedLine"
    /// Same key `BusCatalogStore` owns; it is reused, never renamed (spec S5).
    static let busSelectedLineKey = "busSelectedLine"

    static let metroMode = AppModeCode.metro
    static let busMode = AppModeCode.bus
    static let fgcMode = AppModeCode.fgc
    static let rodaliesMode = AppModeCode.rodalies

    private let defaults: UserDefaults

    /// Visible tab.
    var selectedTab: AppTab = .map
    /// Whether the "A prop teu" sheet is open over the map (redesign S13).
    /// Set by the map's location button and the home-screen quick action; the
    /// map screens read it to draw the location button filled while it is on.
    var isNearbyPresented = false
    /// Focus the map has not handled yet.
    private(set) var pendingFocus: Destination?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Persists the mode and line the destination needs, switches to the map
    /// tab and records the focus.
    func open(_ destination: Destination) {
        switch destination {
        case .place:
            break
        case .line(let `operator`, let code):
            persistLineCode(code, operator: `operator`)
        case .vehicle(let `operator`, let lineCode, _):
            persistLineCode(lineCode, operator: `operator`)
        }

        defaults.set(destination.operator, forKey: Self.appModeKey)
        selectedTab = .map
        pendingFocus = destination
    }

    /// The mode the app is effectively on, read from the persisted keys (#44).
    ///
    /// `appMode` is written by `open(_:)` and by the mode menu only, while
    /// browsing lines in the default metro mode persists just
    /// `metroSelectedLine`. A fresh install is therefore on the metro mode its
    /// screens default to (`AppMode.metro`), and this is the value the
    /// home-screen line quick action has to read.
    static func effectiveMode(defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: appModeKey) ?? metroMode
    }

    /// Marks the focus as handled.
    func clearFocus() {
        pendingFocus = nil
    }

    /// Returns the focus and clears it, for a screen that handles it in one go.
    func takeFocus() -> Destination? {
        defer { pendingFocus = nil }
        return pendingFocus
    }

    // MARK: - Selected line

    /// Metro stores the TMB line code ("1", "94"); FGC stores the route code
    /// ("S1"); Rodalies stores the line code ("R1", "R2N"); bus stores the
    /// numeric `CODI_LINIA` the catalog uses ("212").
    /// Metro also accepts the display name ("L1"), because places expose it.
    private func persistLineCode(_ code: String, operator name: String) {
        switch name {
        case Self.metroMode:
            let lineCode = MetroLine.allLines.first {
                $0.code == code || $0.displayName.caseInsensitiveCompare(code) == .orderedSame
            }?.code ?? code
            defaults.set(lineCode, forKey: Self.metroSelectedLineKey)
        case Self.fgcMode:
            defaults.set(code, forKey: Self.fgcSelectedLineKey)
        case Self.rodaliesMode:
            defaults.set(code, forKey: Self.rodaliesSelectedLineKey)
        case Self.busMode:
            if let numeric = Int(code) {
                defaults.set(numeric, forKey: Self.busSelectedLineKey)
            } else if let line = BusCatalogStore.shared.lines.first(where: {
                $0.name.caseInsensitiveCompare(code) == .orderedSame
            }) {
                defaults.set(line.code, forKey: Self.busSelectedLineKey)
            }
        default:
            break
        }
    }
}
