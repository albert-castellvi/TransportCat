import Foundation

/// Termini text of a metro line, read from the topology cache (spec S4):
/// "Bellvitge – Fondo" for L1, or nil while the line has never loaded.
///
/// This is static catalog data, not a poll: `LineState` persists every
/// successful topology load into `OfflineCache` (spec S21 of the previous
/// design), and this helper only reads that copy, so the bottom accessory's
/// line chip can name the line's endpoints without a second fetcher.
enum MetroLineTermini {
    /// "Bellvitge – Fondo" for the line's last cached topology, ordered by the
    /// stations' order in the line. Nil without a usable cached copy or with
    /// fewer than two stations.
    static func cachedTermini(lineCode: String, cache: DiskCache = .shared) -> String? {
        guard let topology = OfflineCache.loadMetroTopology(lineCode: lineCode, cache: cache),
              topology.stations.count >= 2 else { return nil }
        let ordered = topology.stations.sorted { $0.orderInLine < $1.orderInLine }
        return "\(ordered[0].name) – \(ordered[ordered.count - 1].name)"
    }

    /// Termini for several lines at once, keyed by line code, so a list can
    /// fill its rows from one pass over the cache instead of one read per
    /// rendered row.
    static func cachedTerminiMap(lineCodes: [String], cache: DiskCache = .shared) -> [String: String] {
        var result: [String: String] = [:]
        for code in lineCodes {
            if let termini = cachedTermini(lineCode: code, cache: cache) {
                result[code] = termini
            }
        }
        return result
    }
}
