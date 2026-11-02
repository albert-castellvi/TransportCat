import Foundation

/// One-line occupancy summary of a train, from the per-car percentages the
/// FGC live feed reports (spec S18).
///
/// Pure thresholds over plain values, so the lines-screen badges and the map
/// markers' accessibility labels share one wording and one test.
enum FGCOccupancy {
    /// Mean below this is "Ocupació baixa" (spec S18: under 40 %).
    static let lowCeilingPercent = 40
    /// Mean up to and including this is "Ocupació mitjana" (spec S18: 40–70 %).
    static let mediumCeilingPercent = 70

    /// The Catalan summary of the reported cars' mean occupancy, or nil when
    /// the feed reports no car at all — in that case the UI omits the summary
    /// instead of inventing one.
    static func summary(_ percents: [Int?]) -> String? {
        let reported = percents.compactMap { $0 }
        guard !reported.isEmpty else { return nil }
        let mean = Double(reported.reduce(0, +)) / Double(reported.count)
        if mean < Double(lowCeilingPercent) {
            return "Ocupació baixa"
        }
        if mean <= Double(mediumCeilingPercent) {
            return "Ocupació mitjana"
        }
        return "Ocupació alta"
    }

    /// The summary of one train's cars, in feed order.
    static func summary(_ train: FGCTrain) -> String? {
        summary(train.occupancy.map(\.percent))
    }
}
