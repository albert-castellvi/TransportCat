import Foundation

/// The searches that led somewhere, newest first (review W9).
///
/// Typing on a watch costs a dictation or a scribble, so the search screen
/// offers the last few queries back as a single tap. Foundation-only, so the
/// rule can be exercised without a UI.
enum WatchRecentSearches {
    /// Versioned key. A change of the stored shape must use a new key.
    static let key = "watchRecentSearches.v1"

    /// How many queries the screen offers back.
    static let limit = 3

    static func read(from defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: key) ?? []
    }

    /// Records `query` at the front, dropping an older copy of the same query
    /// (compared the way search compares, so "Sagrera" and "sagrerà" are one
    /// entry), and keeps at most `limit`.
    ///
    /// - Returns: the stored list, so the caller can update its own copy
    ///   without a second `UserDefaults` read.
    @discardableResult
    static func record(_ query: String, defaults: UserDefaults = .standard) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return read(from: defaults) }

        let needle = PlaceIndex.normalized(trimmed)
        var entries = read(from: defaults).filter { PlaceIndex.normalized($0) != needle }
        entries.insert(trimmed, at: 0)
        if entries.count > limit {
            entries.removeLast(entries.count - limit)
        }
        defaults.set(entries, forKey: key)
        return entries
    }
}
