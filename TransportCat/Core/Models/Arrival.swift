import Foundation

/// A live arrival of a train at a stop, from the TMB iBus service.
struct Arrival: Identifiable, Hashable {
    /// TMB stop code this arrival was queried for.
    let stationCode: Int
    /// Line code the query was made for.
    let lineCode: String
    /// Transport destination shown by TMB, e.g. "Fondo".
    let destination: String
    /// Seconds until the arrival, when iBus reported a numeric countdown.
    /// nil for non-numeric values ("Aprox.", "—", "+inf", ...).
    let seconds: Int?
    /// Raw countdown text as reported by iBus (e.g. "2 min").
    let rawText: String

    var id: String { "\(lineCode)-\(stationCode)-\(rawText)-\(destination)" }
}
