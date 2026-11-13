import Foundation

/// Pure formatting of the Explora tab (spec S12): the distance and walking
/// captions of "A prop", the arrivals limit of "Preferits" and the ranking of
/// the line search. Foundation-only so the rules run in tests and in the Linux
/// harness without a UI.
enum ExploreFormatting {
    /// Places listed under "A prop" and the radius they must sit inside —
    /// the same defaults `PlaceIndex.nearest` documents.
    static let nearbyLimit = 10
    static let nearbyRadiusMeters: Double = 1_000

    /// Flat walking speed the "n min a peu" caption assumes (S12).
    static let walkingSpeedMetersPerMinute: Double = 80

    /// Arrivals shown per favorite place (S12).
    static let arrivalsPerPlace = 2

    /// "350 m" under a kilometer, "1,2 km" above, with the Catalan decimal
    /// comma. Values are rounded before the unit is picked, so 999.6 m reads
    /// "1,0 km" instead of the nonsensical "1000 m". A negative distance (a
    /// broken caller) clamps to zero.
    static func distanceText(meters: Double) -> String {
        let clamped = max(0, meters.rounded())
        guard clamped >= 1_000 else { return String(localized: "\(Int(clamped)) m") }
        // Tenths of a kilometer, so "1,2 km" is two integer parts and never a
        // locale-dependent float format.
        let tenths = Int((clamped / 100).rounded())
        return String(localized: "\(tenths / 10),\(tenths % 10) km")
    }

    /// Walking minutes at `walkingSpeedMetersPerMinute`, rounded to the
    /// nearest minute as the spec example does (350 m → "4 min a peu"), with a
    /// floor of 1 for any non-zero distance. Zero distance walks zero minutes.
    static func walkingMinutes(meters: Double) -> Int {
        guard meters > 0 else { return 0 }
        return max(1, Int((meters / walkingSpeedMetersPerMinute).rounded()))
    }

    /// "4 min a peu".
    static func walkingText(meters: Double) -> String {
        String(localized: "\(walkingMinutes(meters: meters)) min a peu")
    }

    /// The "A prop" row caption: "350 m · 4 min a peu".
    static func nearbyCaption(meters: Double) -> String {
        "\(distanceText(meters: meters)) · \(walkingText(meters: meters))"
    }

    /// Line-search rank over the fields a line can be found by (name, code):
    /// nil when no field matches, 0 for an exact folded field, 1 when the
    /// field — or one of its words — starts with the query, 2 when the query
    /// only sits inside one. Same ranking as `PlaceIndex.search`, so lines and
    /// places sort alike. The best (lowest) rank across the fields wins, so
    /// "9" over ["L9N", "94"] is a prefix hit, not a substring one. Folding
    /// reuses `PlaceIndex.normalized`.
    static func bestLineRank(fields: [String], query: String) -> Int? {
        let needle = PlaceIndex.normalized(query)
        guard !needle.isEmpty else { return nil }
        var best: Int?
        for field in fields {
            let folded = PlaceIndex.normalized(field)
            guard !folded.isEmpty else { continue }
            let rank: Int?
            if folded == needle {
                rank = 0
            } else if folded.hasPrefix(needle) || PlaceIndex.hasWordPrefix(folded, needle) {
                rank = 1
            } else if folded.contains(needle) {
                rank = 2
            } else {
                rank = nil
            }
            guard let rank else { continue }
            best = best.map { min($0, rank) } ?? rank
        }
        return best
    }
}
