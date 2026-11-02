import Foundation

extension FGCNetworkState {
    /// The one live state both FGC screens draw from (spec S6, S7, S9).
    ///
    /// Like `AppModel.shared` and `BusCatalogStore.shared` it exists so the map
    /// and the lines screen always show the same lines, trains and freshness
    /// without a second copy to keep in sync. Its `run()` loop is started by
    /// exactly one owner: the `.task(id: mode)` in `RootView`, which cancels it
    /// when the rider leaves FGC mode, so there is never more than one poller.
    static let shared = FGCNetworkState()
}

/// Which stations belong to which line (spec S7, S9).
///
/// `codigo-estaciones` is published per *network* (1 Barcelona-Vallès,
/// 2 Llobregat-Anoia...), not per route code, so there is no code-to-station
/// table in the data. The join that works is geometric — probed against the
/// live portal on 2026-11-02: every station a line actually serves lies within
/// ~150 m of one of its polylines, and every other station is more than 400 m
/// away. Shared by both screens so the map dots and the list can never differ.
enum FGCLineStations {
    /// Maximum perpendicular distance from a station point to the line's
    /// polylines for the station to count as belonging to the line. Sits in
    /// the empty band between the two populations of the probe above, and is
    /// well under the 300 m snap distance the glide uses (S5).
    static let maxOffsetMeters = 180.0

    /// The stations of one layer, sorted by `codigo-estaciones.ordre`, deduped
    /// by code (the lowest `ordre` of a repeated code wins). A layer without a
    /// polyline has no derivable stations and yields an empty list.
    static func stations(for layer: MapLineLayer?, in stations: [FGCStation]) -> [FGCStation] {
        guard let layer, !layer.polylines.isEmpty else { return [] }
        let geometry = FGCNetwork.geometry(polylines: layer.polylines)
        var seen: Set<String> = []
        return stations
            .sorted { lhs, rhs in
                lhs.order == rhs.order ? lhs.code < rhs.code : lhs.order < rhs.order
            }
            .filter { station in
                guard let point = station.point,
                      FGCNetwork.snap(point, in: geometry, maxOffsetMeters: maxOffsetMeters) != nil else {
                    return false
                }
                return seen.insert(station.code).inserted
            }
    }
}
