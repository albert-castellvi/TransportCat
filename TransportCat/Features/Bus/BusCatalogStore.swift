import Foundation
import Observation

/// Catalog of bus lines shared by every bus screen: the lines themselves,
/// loaded once per launch (spec S2), plus the picker state a rider expects to
/// find again — the starred lines and the line selected last.
///
/// `@MainActor @Observable` like `LineState`: the screens read it directly from
/// a view, and only the main actor ever mutates it.
@MainActor
@Observable
final class BusCatalogStore {
    /// Single catalog: the screens hand it to the picker by reference, so a
    /// favorite toggled in one sheet shows up in the other.
    static let shared = BusCatalogStore()

    /// Loaded catalog, in the order the API returns it. Grouping by family is
    /// the picker's job (`BusCatalog.families(of:)`), not the store's.
    private(set) var lines: [BusLine] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    /// Codes of the starred lines, in the order they were starred (spec S2).
    private(set) var favorites: [Int]

    /// Line on screen. Persisted, so the bus map and the bus Línies screen open
    /// on the same line the rider left (spec S2).
    var selectedLineCode: Int? {
        didSet {
            guard oldValue != selectedLineCode else { return }
            BusCatalogDefaults.writeSelectedLineCode(selectedLineCode)
        }
    }

    /// The line `selectedLineCode` names among the loaded ones; nil while the
    /// catalog has not loaded, or when nothing is selected yet.
    var selectedLine: BusLine? {
        guard let selectedLineCode else { return nil }
        return lines.first { $0.code == selectedLineCode }
    }

    init() {
        favorites = BusCatalogDefaults.readFavorites()
        selectedLineCode = BusCatalogDefaults.readSelectedLineCode()
    }

    /// Loads the catalog once per launch: a second call returns immediately and
    /// keeps the lines already on screen (spec S2). A failed load leaves the
    /// lines empty, so the "Reintenta" button of the picker can call this again.
    func load(client: TMBClient) async {
        guard lines.isEmpty, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded = try await client.busLines()
            lines = loaded
            errorMessage = nil
            applyDefaultSelectionIfNeeded()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Stars or unstars a line and persists the list (spec S2).
    func toggleFavorite(_ line: BusLine) {
        if let index = favorites.firstIndex(of: line.code) {
            favorites.remove(at: index)
        } else {
            favorites.append(line.code)
        }
        BusCatalogDefaults.writeFavorites(favorites)
    }

    func isFavorite(_ line: BusLine) -> Bool {
        favorites.contains(line.code)
    }

    /// With a catalog and no usable selection: the first favorite, else the
    /// "H12" the prototype is drawn with, else the first line of the catalog.
    private func applyDefaultSelectionIfNeeded() {
        guard selectedLine == nil, !lines.isEmpty else { return }
        let firstFavorite = favorites.first { code in lines.contains { $0.code == code } }
        let chosen = firstFavorite ?? lines.first { $0.name == "H12" }?.code ?? lines.first?.code
        if let chosen {
            selectedLineCode = chosen
        }
    }
}

/// UserDefaults access of the picker state, in one tiny helper so the store
/// body stays about lines and selection (spec S2).
private enum BusCatalogDefaults {
    static let favoritesKey = "busFavorites"
    static let selectedLineKey = "busSelectedLine"

    /// Saved line codes. Anything stored under the key that is not an array of
    /// integers reads as "no favorites" instead of crashing.
    static func readFavorites() -> [Int] {
        (UserDefaults.standard.array(forKey: favoritesKey) as? [Int]) ?? []
    }

    static func writeFavorites(_ codes: [Int]) {
        UserDefaults.standard.set(codes, forKey: favoritesKey)
    }

    /// `integer(forKey:)` answers 0 for an absent key, so presence is checked
    /// through `object` to keep "never chosen" different from line 0.
    static func readSelectedLineCode() -> Int? {
        UserDefaults.standard.object(forKey: selectedLineKey) as? Int
    }

    static func writeSelectedLineCode(_ code: Int?) {
        if let code {
            UserDefaults.standard.set(code, forKey: selectedLineKey)
        } else {
            UserDefaults.standard.removeObject(forKey: selectedLineKey)
        }
    }
}
