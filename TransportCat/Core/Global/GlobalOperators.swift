import Foundation

/// The operator filter chips of the global map (spec S8): Metro, Bus and FGC
/// toggles persisted in UserDefaults under the key `globalOperators`.
enum GlobalOperator: String, CaseIterable {
    case metro
    case bus
    case fgc

    /// The chip title. These are brand names, identical in Catalan.
    var label: String {
        switch self {
        case .metro: return "Metro"
        case .bus: return "Bus"
        case .fgc: return "FGC"
        }
    }
}

/// The comma-joined token list stored under `globalOperators`. Kept pure so
/// the chip row only has to read and write one `@AppStorage` string.
enum GlobalOperatorSelection {
    /// UserDefaults key of the selection (spec S8).
    static let storageKey = "globalOperators"

    /// First-launch value: every operator visible.
    static let defaultRaw = "metro,bus,fgc"

    /// The selection a stored string describes. Unknown tokens (an operator
    /// renamed in a future build) and empty slots are ignored, so a damaged
    /// value degrades to fewer chips, never to a crash.
    static func decode(_ raw: String) -> Set<GlobalOperator> {
        Set(raw.split(separator: ",").compactMap { GlobalOperator(rawValue: $0.trimmingCharacters(in: .whitespaces)) })
    }

    /// The stored string for a selection, tokens in `CaseIterable` order so a
    /// re-save of the same set never changes the value.
    static func encode(_ selection: Set<GlobalOperator>) -> String {
        GlobalOperator.allCases.filter { selection.contains($0) }
            .map(\.rawValue)
            .joined(separator: ",")
    }
}
