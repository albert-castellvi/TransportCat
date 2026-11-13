import Foundation
import Observation

/// One favorite metro or FGC line (spec S4).
///
/// Bus line favorites are not duplicated here: they stay in
/// `BusCatalogStore`'s `busFavorites` key, which already exists.
struct FavoriteLine: Codable, Hashable, Identifiable {
    /// "metro" or "fgc".
    let `operator`: String
    /// The code the operator's screens use: metro "1", FGC "S1".
    let code: String

    var id: String { "\(`operator`):\(code)" }

    static let metro = "metro"
    static let fgc = "fgc"
}

/// Favorite places and favorite metro/FGC lines, persisted in `UserDefaults`
/// (spec S4).
///
/// The two lists live under their own versioned keys so a future model change
/// can migrate one without touching the other. Both are read tolerantly: a
/// value that is not our JSON reads as an empty list instead of crashing.
@Observable
final class FavoritesStore {
    static let shared = FavoritesStore()

    static let placesKey = "favoritePlaces.v1"
    static let linesKey = "favoriteLines.v1"

    /// App Group shared by the app and the widget extension, so the widget's
    /// place suggestions can read the app's favorites.
    static let appGroup = "group.cat.transport.app"

    /// The group suite, created once. Favorites saved before the group existed
    /// live in `.standard`; they are copied over the first time. Falls back to
    /// `.standard` when the group is unavailable (unsigned builds).
    static let sharedDefaults: UserDefaults = {
        let group = UserDefaults(suiteName: appGroup) ?? .standard
        migrateLegacy(from: .standard, to: group)
        return group
    }()

    /// Copies each favorites key from `source` to `destination` unless the
    /// destination already has one, so a newer group value is never overwritten.
    static func migrateLegacy(from source: UserDefaults, to destination: UserDefaults) {
        for key in [placesKey, linesKey] where destination.object(forKey: key) == nil {
            if let data = source.data(forKey: key) {
                destination.set(data, forKey: key)
            }
        }
    }

    private let defaults: UserDefaults

    /// Favorite places, in the order they were starred.
    private(set) var favoritePlaces: [Place]
    /// Favorite metro/FGC lines, in the order they were starred.
    private(set) var favoriteLines: [FavoriteLine]

    /// - Parameter defaults: injectable suite, so tests do not touch the app's
    ///   domain.
    init(defaults: UserDefaults = FavoritesStore.sharedDefaults) {
        self.defaults = defaults
        favoritePlaces = Self.read([Place].self, key: Self.placesKey, defaults: defaults) ?? []
        favoriteLines = Self.read([FavoriteLine].self, key: Self.linesKey, defaults: defaults) ?? []
    }

    // MARK: - Places

    func isFavorite(_ place: Place) -> Bool {
        favoritePlaces.contains { $0.id == place.id }
    }

    /// Stars the place, or unstars it when it already is.
    func toggle(_ place: Place) {
        if let index = favoritePlaces.firstIndex(where: { $0.id == place.id }) {
            favoritePlaces.remove(at: index)
        } else {
            favoritePlaces.append(place)
        }
        Self.write(favoritePlaces, key: Self.placesKey, defaults: defaults)
    }

    /// Reorders the favorite places (drag-to-reorder in Explora) and persists
    /// the new order the same way `toggle` does. `source` and `destination`
    /// are the offsets `.onMove` reports: `source` holds the rows being moved,
    /// `destination` is the offset they move to in the list before the move.
    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        favoritePlaces = Self.moved(favoritePlaces, fromOffsets: source, toOffset: destination)
        Self.write(favoritePlaces, key: Self.placesKey, defaults: defaults)
    }

    /// Removes the favorite places at `offsets`, the way `.onDelete` reports
    /// them (Configuració's editable list), and persists the shorter list.
    func remove(atOffsets offsets: IndexSet) {
        favoritePlaces.remove(atOffsets: offsets)
        Self.write(favoritePlaces, key: Self.placesKey, defaults: defaults)
    }

    // MARK: - Lines

    func isFavorite(_ line: FavoriteLine) -> Bool {
        favoriteLines.contains(line)
    }

    /// Stars the line, or unstars it when it already is.
    func toggle(_ line: FavoriteLine) {
        if let index = favoriteLines.firstIndex(of: line) {
            favoriteLines.remove(at: index)
        } else {
            favoriteLines.append(line)
        }
        Self.write(favoriteLines, key: Self.linesKey, defaults: defaults)
    }

    // MARK: - Persistence

    /// Foundation-only reorder equivalent of `.onMove`: removes the elements
    /// at `source` and reinserts them, in their original order, before
    /// `destination`, so `destination` is understood in the pre-move list
    /// exactly as SwiftUI's `.onMove` reports it.
    private static func moved<T>(_ elements: [T], fromOffsets source: IndexSet, toOffset destination: Int) -> [T] {
        var elements = elements
        let moving = source.sorted().map { elements[$0] }
        for index in source.sorted(by: >) {
            elements.remove(at: index)
        }
        let removedBefore = source.reduce(into: 0) { count, index in
            if index < destination { count += 1 }
        }
        elements.insert(contentsOf: moving, at: destination - removedBefore)
        return elements
    }

    private static func read<T: Decodable>(_ type: T.Type, key: String, defaults: UserDefaults) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func write<T: Encodable>(_ value: T, key: String, defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }
}
