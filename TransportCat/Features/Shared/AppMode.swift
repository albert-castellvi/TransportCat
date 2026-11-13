import Foundation

/// What a tab shows: the existing metro screens, the bus ones, the FGC ones
/// or all operators at once (spec S1, S6, S8).
///
/// Persisted as its raw value in `UserDefaults` under "appMode", so the app
/// reopens on the mode the rider used last. `RootView`, the screens and the
/// bottom accessory's mode menu (redesign S4) read that same key through
/// `@AppStorage`, which is what keeps them in agreement without any explicit
/// wiring.
enum AppMode: String, CaseIterable {
    case metro
    case bus
    /// Ferrocarrils de la Generalitat (spec S6). Its screens read
    /// `FGCNetworkState.shared` instead of the TMB model.
    case fgc
    /// The global mode (spec S8): metro, FGC and the favorite bus routes on
    /// one map. Its screens read `GlobalNetworkState.shared` for the metro
    /// side and `FGCNetworkState.shared` for the FGC side.
    case global

    /// The word the rider reads for this mode: "Metro", "Bus", "FGC", "Tot".
    /// The mode menu and the Configuració picker share it, so a mode is never
    /// named twice in two ways.
    var displayName: String {
        switch self {
        case .metro: return String(localized: "Metro")
        case .bus: return String(localized: "Bus")
        case .fgc: return String(localized: "FGC")
        case .global: return String(localized: "Tot")
        }
    }
}
