import Foundation

/// Catalog operations over the bus lines: grouping by family for the picker
/// and the case- and diacritic-insensitive search behind its search field.
enum BusCatalog {
    /// Groups lines by family. Families follow `BusLine.familyOrder` (the TMB
    /// order: Verticals, Diagonals, Horitzontals, Verticals...) and the lines of
    /// each family follow `BusLine.order`. Unknown fields (`Int.max` orders)
    /// sink to the end instead of jumping to the top.
    static func families(of lines: [BusLine]) -> [BusFamily] {
        var groups: [Int: [BusLine]] = [:]
        for line in lines {
            groups[line.familyCode, default: []].append(line)
        }
        return groups.map { code, familyLines -> BusFamily in
            let ordered = familyLines.sorted { lhs, rhs in
                if lhs.order != rhs.order { return lhs.order < rhs.order }
                return lhs.code < rhs.code
            }
            return BusFamily(
                code: code,
                name: ordered.first?.familyName ?? "",
                order: ordered.first?.familyOrder ?? Int.max,
                lines: ordered
            )
        }
        .sorted { lhs, rhs in
            if lhs.order != rhs.order { return lhs.order < rhs.order }
            return lhs.code < rhs.code
        }
    }

    /// Searches lines by name, description, origin and destination.
    ///
    /// The comparison is case- and diacritic-insensitive, so "besos" finds
    /// "Besòs Verneda". An empty query returns the whole catalog. Results keep
    /// catalog order, except that the lines whose own name matches the query
    /// exactly or as a prefix come first: typing "H12" must put H12 above the
    /// lines that merely pass through a place with that name.
    static func search(_ lines: [BusLine], query: String) -> [BusLine] {
        let needle = normalize(query)
        guard !needle.isEmpty else { return lines }
        var nameMatches: [BusLine] = []
        var otherMatches: [BusLine] = []
        for line in lines {
            let normalizedName = normalize(line.name)
            if normalizedName == needle || normalizedName.hasPrefix(needle) {
                nameMatches.append(line)
            } else if searchableText(of: line).contains(needle) {
                otherMatches.append(line)
            }
        }
        return nameMatches + otherMatches
    }

    /// Everything the search field compares against, already normalized and
    /// separated so a query cannot match across two fields by accident.
    private static func searchableText(of line: BusLine) -> String {
        [line.name, line.description, line.origin, line.destination]
            .map(normalize)
            .joined(separator: "\u{0}")
    }

    /// Case- and diacritic-insensitive folding ("Besòs" -> "besos"). The
    /// Catalan locale keeps the fold stable for the middle dot ("l·l").
    private static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "ca_ES"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
