import Foundation

/// The next stop of one trip and when Renfe expects the train to reach it.
///
/// Renfe's `trip_updates.json` publishes, per trip, the stop the train is
/// heading to and its predicted arrival. That pair is what lets the map place a
/// train between two stations even though the vehicle feed mostly repeats the
/// coordinate of a stop. Foundation only: the map's estimation logic and its
/// tests build on it, and it must stay compilable without Apple frameworks.
struct RodaliesTripETA: Equatable {
    /// The trip the prediction belongs to (`5121X25661R1`).
    let tripID: String
    /// GTFS `stop_id` of the next stop (`79404`, Badalona).
    let nextStopID: String
    /// Predicted arrival at `nextStopID`, as published by Renfe.
    let predictedArrival: Date
}

extension RodaliesParser {
    /// Trip id -> next stop and predicted arrival of `trip_updates.json`,
    /// nucleus trips only.
    ///
    /// The first `stopTimeUpdate` that carries both a `stopId` and a time wins,
    /// and `arrival.time` is preferred over `departure.time`; later stop updates
    /// are not predictions for a train that has already reached them. A trip
    /// without that pair is not in the map, which keeps "no prediction" apart
    /// from "predicted on time".
    ///
    /// Predictions are read as published, without judging them: an ETA eight
    /// minutes in the past or ninety minutes ahead is syntactically valid and
    /// only becomes impossible against a clock. `RodaliesTripProgress` owns that
    /// decision, so the parser stays a pure decoder and both layers keep one
    /// testable responsibility each.
    static func tripETAs(from data: Data, knownLines: [String]) -> [String: RodaliesTripETA] {
        guard let entities = entities(from: data) else { return [:] }
        var etas: [String: RodaliesTripETA] = [:]
        for entity in entities {
            guard let update = JSONValue.dictionary(from: entity["tripUpdate"]),
                  let trip = JSONValue.dictionary(from: update["trip"]),
                  let tripID = JSONValue.string(from: trip["tripId"]), !tripID.isEmpty,
                  lineCode(fromTripID: tripID, knownLines: knownLines) != nil else { continue }
            for value in JSONValue.array(from: update["stopTimeUpdate"]) ?? [] {
                guard let entry = JSONValue.dictionary(from: value),
                      let nextStopID = JSONValue.string(from: entry["stopId"]), !nextStopID.isEmpty else { continue }
                let arrival = JSONValue.dictionary(from: entry["arrival"])
                let departure = JSONValue.dictionary(from: entry["departure"])
                guard let predictedArrival = epochDate(from: arrival?["time"])
                    ?? epochDate(from: departure?["time"]) else { continue }
                etas[tripID] = RodaliesTripETA(
                    tripID: tripID,
                    nextStopID: nextStopID,
                    predictedArrival: predictedArrival
                )
                break
            }
        }
        return etas
    }

    /// A GTFS-Realtime epoch, published as a string in Renfe's feeds but read
    /// from a number too so a re-encoded fixture keeps working.
    private static func epochDate(from value: Any?) -> Date? {
        if let seconds = JSONValue.double(from: value) {
            return Date(timeIntervalSince1970: seconds)
        }
        if let text = JSONValue.string(from: value), let seconds = Double(text) {
            return Date(timeIntervalSince1970: seconds)
        }
        return nil
    }
}
