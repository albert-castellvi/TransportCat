import Foundation

/// A place plus its distance from the query point, in meters (spec S1).
struct PlaceDistance: Hashable, Identifiable {
    let place: Place
    let distance: Double

    var id: String { place.id }
}

/// Pure place rules: search ranking, nearest places and interchanges (spec S1).
///
/// Kept free of SwiftUI and of any store, so the ordering rules run in tests and
/// in the Linux harness without a network or a clock.
enum PlaceIndex {
    /// Case- and diacritic-insensitive comparison used by search and by the
    /// interchange name rule ("Pl. Catalunya" matches "PL. CATALUNYA").
    static func normalized(_ text: String) -> String {
        text
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "ca_ES"))
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    /// Places whose name matches `query`, best match first.
    ///
    /// Ranking, in order: the name starts with the query, a word of the name
    /// starts with it, the query appears inside the name. Ties break on the
    /// name and then on the id, so the same input always yields the same list.
    /// An empty or whitespace-only query finds nothing, which is what the
    /// searchable screen wants before the rider types.
    static func search(query: String, places: [Place], limit: Int = 20) -> [Place] {
        let needle = normalized(query)
        guard !needle.isEmpty, limit > 0 else { return [] }

        var matches: [(rank: Int, name: String, id: String, place: Place)] = []
        for place in places {
            let name = normalized(place.name)
            guard !name.isEmpty else { continue }
            if name.hasPrefix(needle) {
                matches.append((0, name, place.id, place))
            } else if hasWordPrefix(name, needle) {
                matches.append((1, name, place.id, place))
            } else if name.contains(needle) {
                matches.append((2, name, place.id, place))
            }
        }

        return matches
            .sorted { lhs, rhs in
                if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
                if lhs.name != rhs.name { return lhs.name < rhs.name }
                return lhs.id < rhs.id
            }
            .prefix(limit)
            .map(\.place)
    }

    static func hasWordPrefix(_ name: String, _ needle: String) -> Bool {
        name.split(separator: " ").contains { $0.hasPrefix(needle) }
    }

    /// The places within `maxDistance` meters of `point`, closest first.
    static func nearest(
        to point: GeoPoint,
        places: [Place],
        limit: Int = 10,
        maxDistance: Double = 1_000
    ) -> [PlaceDistance] {
        guard limit > 0 else { return [] }
        let found = places.compactMap { place -> PlaceDistance? in
            let distance = GeoMath.distanceMeters(from: point, to: place.position)
            guard distance <= maxDistance else { return nil }
            return PlaceDistance(place: place, distance: distance)
        }
        return found
            .sorted { lhs, rhs in
                if lhs.distance != rhs.distance { return lhs.distance < rhs.distance }
                if lhs.place.name != rhs.place.name { return lhs.place.name < rhs.place.name }
                return lhs.place.id < rhs.place.id
            }
            .prefix(limit)
            .map { $0 }
    }

    /// Other places that count as an interchange of `place` (spec S1): every
    /// place within `radius` meters, plus metro stations that share its name
    /// (the two halves of a transfer are not always within the radius).
    ///
    /// `place` itself is always excluded, and each result appears once.
    static func interchanges(for place: Place, places: [Place], radius: Double = 250) -> [Place] {
        let name = normalized(place.name)
        var seen: Set<String> = [place.id]
        var found: [Place] = []

        for candidate in places where !seen.contains(candidate.id) {
            let sameName = candidate.kind == .metroStation
                && place.kind == .metroStation
                && normalized(candidate.name) == name
            let nearby = GeoMath.distanceMeters(from: place.position, to: candidate.position) <= radius
            guard sameName || nearby else { continue }
            seen.insert(candidate.id)
            found.append(candidate)
        }

        return found.sorted { lhs, rhs in
            let lhsDistance = GeoMath.distanceMeters(from: place.position, to: lhs.position)
            let rhsDistance = GeoMath.distanceMeters(from: place.position, to: rhs.position)
            if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
            if lhs.name != rhs.name { return lhs.name < rhs.name }
            return lhs.id < rhs.id
        }
    }
}
