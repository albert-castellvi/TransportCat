import Foundation

/// A live arrival of a metro train at a station, from the TMB i-Metro service.
struct Arrival: Identifiable, Hashable {
    /// TMB station code this arrival was queried for.
    let stationCode: Int
    /// Line code the query was made for.
    let lineCode: String
    /// Transport destination shown by TMB, e.g. "Fondo".
    let destination: String
    /// Seconds until the arrival, derived from the i-Metro timestamp.
    /// Clamped at 0 for an overdue train.
    let seconds: Int?
    /// Countdown text shown next to the destination (e.g. "2 min").
    let rawText: String
    /// i-Metro `codi_servei`, the code identifying the train run. Two trains
    /// can reach one station in the same minute with the same destination, so
    /// the countdown text does not identify an arrival uniquely. Optional with
    /// a default value so callers that do not know the train run keep using
    /// the memberwise initializer unchanged.
    var serviceCode: String? = nil

    var id: String {
        if let serviceCode {
            return "\(lineCode)-\(stationCode)-\(serviceCode)"
        }
        return "\(lineCode)-\(stationCode)-\(rawText)-\(destination)"
    }
}

extension Arrival {
    /// The single countdown formatter of the app: arrivals under a minute read
    /// "<1 min" instead of the "0 min" that integer division would produce.
    static func countdownText(seconds: Int) -> String {
        seconds < 60 ? "<1 min" : "\(seconds / 60) min"
    }
}
