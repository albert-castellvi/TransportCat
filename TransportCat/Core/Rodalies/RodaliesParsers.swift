import Foundation

/// One vehicle of Renfe's GTFS-Realtime `vehicle_positions.json`, after the
/// nucleus filter.
struct RodaliesVehiclePosition: Equatable {
    let tripID: String
    /// Line code read from the trip id (`5116V18122R16` -> "R16").
    let lineCode: String
    /// `vehicle.id`, Renfe's train number.
    let vehicleID: String
    /// `vehicle.label`, sometimes carrying the platform; kept as a fallback.
    let label: String?
    let position: GeoPoint
    let bearingDegrees: Double?
    let timestamp: Date?
    let stopID: String?
    let status: String?
}

/// What one nucleus trip's `trip_updates.json` entity says, after the feed's
/// own filtering: the delay, the real next stop and, when the feed sends it,
/// the predicted arrival there.
struct RodaliesTripUpdate: Equatable {
    /// Trip-level delay in seconds, or the first stop's delay when the trip
    /// carries none. Nil means the feed says nothing about this trip's timing.
    let delaySeconds: Int?
    /// The first `stopTimeUpdate` stop: GTFS-Realtime's next stop for the trip.
    /// This is the real next stop, unlike the vehicle's `stopId` for an
    /// `IN_TRANSIT_TO` vehicle, which is the stop it just left.
    let nextStopID: String?
    /// Predicted arrival at `nextStopID`, when the feed sends `arrival.time`.
    let predictedArrival: Date?
}

/// Tolerant parsers for the two Renfe GTFS-Realtime JSON feeds.
///
/// Every payload is decoded with `JSONSerialization`, the same path the TMB and
/// FGC parsers use: a malformed entity is skipped, never fatal, because one bad
/// train must not blank the whole map. Only the Catalonia-nucleus trips are
/// kept, decided by the trip id's line suffix against the lines of the bundled
/// topology.
enum RodaliesParser {
    /// The nucleus line a Renfe trip id names.
    ///
    /// Renfe codes the id as `<service><train><line>`: `5116V18122R16` is train
    /// 18122 of line R16, `5115J15000R15` train 15000 of R15. The line is the
    /// suffix, so the longest known code wins (`R2N` before `R2`, `R11` before
    /// `R1`) and a suffix that leaves no service/train prefix does not count.
    static func lineCode(fromTripID tripID: String, knownLines: [String]) -> String? {
        guard !tripID.isEmpty else { return nil }
        for code in knownLines.sorted(by: { $0.count > $1.count }) where !code.isEmpty {
            guard tripID.hasSuffix(code), tripID.count > code.count else { continue }
            return code
        }
        return nil
    }

    /// Renfe's train number inside a trip id (`5116V18122R16` -> "18122").
    /// Nil when the id does not end with digits before its line suffix.
    static func trainNumber(fromTripID tripID: String, lineCode: String) -> String? {
        guard tripID.hasSuffix(lineCode) else { return nil }
        let head = tripID.dropLast(lineCode.count)
        let digits = head.reversed().prefix { $0.isNumber }.reversed()
        return digits.isEmpty ? nil : String(digits)
    }

    /// The `entity` array of a GTFS-Realtime JSON feed.
    static func entities(from data: Data) -> [[String: Any]]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entities = JSONValue.array(from: root["entity"]) else { return nil }
        return entities.compactMap { JSONValue.dictionary(from: $0) }
    }

    // MARK: - Vehicle positions

    /// The nucleus vehicles of `vehicle_positions.json`.
    ///
    /// An entity without a position is the documented case of a train with no
    /// GPS fix: it is skipped, because a marker without coordinates has nowhere
    /// to be drawn.
    static func vehicles(from data: Data, knownLines: [String]) -> [RodaliesVehiclePosition] {
        guard let entities = entities(from: data) else { return [] }
        var result: [RodaliesVehiclePosition] = []
        for entity in entities {
            guard let vehicle = JSONValue.dictionary(from: entity["vehicle"]),
                  let trip = JSONValue.dictionary(from: vehicle["trip"]),
                  let tripID = JSONValue.string(from: trip["tripId"]), !tripID.isEmpty,
                  let lineCode = lineCode(fromTripID: tripID, knownLines: knownLines),
                  let position = JSONValue.dictionary(from: vehicle["position"]),
                  let latitude = JSONValue.double(from: position["latitude"]),
                  let longitude = JSONValue.double(from: position["longitude"]) else { continue }
            let identity = JSONValue.dictionary(from: vehicle["vehicle"])
            let vehicleID = JSONValue.string(from: identity?["id"])
                ?? JSONValue.string(from: identity?["label"])
                ?? tripID
            result.append(
                RodaliesVehiclePosition(
                    tripID: tripID,
                    lineCode: lineCode,
                    vehicleID: vehicleID,
                    label: JSONValue.string(from: identity?["label"]),
                    position: GeoPoint(latitude: latitude, longitude: longitude),
                    bearingDegrees: JSONValue.double(from: position["bearing"]),
                    timestamp: timestamp(from: vehicle["timestamp"]),
                    stopID: JSONValue.string(from: vehicle["stopId"]),
                    status: JSONValue.string(from: vehicle["currentStatus"])
                )
            )
        }
        return result
    }

    // MARK: - Trip updates

    /// Trip id -> delay in seconds of `trip_updates.json`, nucleus trips only.
    ///
    /// Kept as the delay-only view of `tripUpdates` for the boards that do not
    /// need the next stop; both share one parse so they cannot disagree.
    static func tripDelays(from data: Data, knownLines: [String]) -> [String: Int] {
        tripUpdates(from: data, knownLines: knownLines).compactMapValues { $0.delaySeconds }
    }

    /// Trip id -> what `trip_updates.json` says about the trip, nucleus trips
    /// only.
    ///
    /// The feed reports the delay at trip level, and beside it per stop. The
    /// trip level wins; when it is absent the first stop that carries one is
    /// used. The first `stopTimeUpdate` supplies the real next stop, which is
    /// how an `IN_TRANSIT_TO` vehicle (whose `stopId` is the stop it left) gets
    /// an honest "Pròxima" instead of the station behind it.
    static func tripUpdates(from data: Data, knownLines: [String]) -> [String: RodaliesTripUpdate] {
        guard let entities = entities(from: data) else { return [:] }
        var updates: [String: RodaliesTripUpdate] = [:]
        for entity in entities {
            guard let update = JSONValue.dictionary(from: entity["tripUpdate"]),
                  let trip = JSONValue.dictionary(from: update["trip"]),
                  let tripID = JSONValue.string(from: trip["tripId"]), !tripID.isEmpty,
                  lineCode(fromTripID: tripID, knownLines: knownLines) != nil else { continue }
            var delay = seconds(update["delay"])
            var nextStopID: String?
            var predictedArrival: Date?
            for entry in JSONValue.array(from: update["stopTimeUpdate"]) ?? [] {
                guard let entry = JSONValue.dictionary(from: entry) else { continue }
                if delay == nil,
                   let arrival = JSONValue.dictionary(from: entry["arrival"]),
                   let stopDelay = seconds(arrival["delay"]) {
                    delay = stopDelay
                }
                if nextStopID == nil,
                   let stopID = JSONValue.string(from: entry["stopId"]),
                   !stopID.isEmpty {
                    nextStopID = stopID
                    if let arrival = JSONValue.dictionary(from: entry["arrival"]) {
                        predictedArrival = timestamp(from: arrival["time"])
                    } else if let departure = JSONValue.dictionary(from: entry["departure"]) {
                        predictedArrival = timestamp(from: departure["time"])
                    }
                }
            }
            updates[tripID] = RodaliesTripUpdate(
                delaySeconds: delay,
                nextStopID: nextStopID,
                predictedArrival: predictedArrival
            )
        }
        return updates
    }

    // MARK: - Join

    /// Joins the positions with the delays, the trip updates and the timetable.
    ///
    /// The trip id gives the line; the timetable gives the direction and the
    /// destination. A trip missing from the pack (a trip id is date-coded, so a
    /// stale pack breaks the join for one day at most) still becomes a train:
    /// the map draws it on its line and the sheet says what it knows.
    ///
    /// The stop fields follow the feed's semantics instead of the convenient
    /// reading (review A.4): an `IN_TRANSIT_TO` vehicle has already left
    /// `stopId`, so it is the current stop and the real next one comes from the
    /// trip update or, failing that, from the direction's stop order. An
    /// `INCOMING_AT` vehicle is at `stopId`, so that stays its next stop.
    static func trains(
        from positions: [RodaliesVehiclePosition],
        delays: [String: Int],
        updates: [String: RodaliesTripUpdate] = [:],
        tripIndex: [String: RodaliesTripInfo],
        topology: RodaliesTopology? = nil
    ) -> [RodaliesLiveTrain] {
        positions.map { position in
            let info = tripIndex[position.tripID]
            let lineCode = info?.lineCode ?? position.lineCode
            let direction = info?.direction
            let update = updates[position.tripID]
            // A trip update that still names the stop the train just left is
            // stale news: the topology's next stop is a better answer.
            let updateNext: String? = update?.nextStopID == position.stopID
                ? nil
                : update?.nextStopID
            let topologyNext = position.stopID.flatMap {
                stopAfter($0, lineCode: lineCode, direction: direction, topology: topology)
            }
            let currentStopID: String?
            let nextStopID: String?
            switch position.status {
            case "INCOMING_AT":
                currentStopID = nil
                // The vehicle is arriving at this stop: it is the next one,
                // whatever else the trip update says.
                nextStopID = position.stopID
            case "IN_TRANSIT_TO":
                currentStopID = position.stopID
                nextStopID = updateNext ?? topologyNext
            case "STOPPED_AT":
                currentStopID = position.stopID
                nextStopID = updateNext ?? topologyNext
            default:
                currentStopID = nil
                nextStopID = position.stopID
            }
            return RodaliesLiveTrain(
                id: position.vehicleID,
                tripID: position.tripID,
                lineCode: lineCode,
                direction: direction,
                headsign: info?.headsign,
                position: position.position,
                bearingDegrees: position.bearingDegrees,
                delaySeconds: delays[position.tripID],
                timestamp: position.timestamp,
                currentStopID: currentStopID,
                nextStopID: nextStopID,
                status: position.status
            )
        }
        .sorted { $0.id < $1.id }
    }

    // MARK: - Helpers

    /// The stop after `stopID` in the trip's direction, from the bundled
    /// topology. Nil when the pack does not know the trip, the direction or
    /// the stop, or the stop is the terminus.
    private static func stopAfter(
        _ stopID: String,
        lineCode: String,
        direction: Int?,
        topology: RodaliesTopology?
    ) -> String? {
        guard let topology, let direction else { return nil }
        let stationIDs = topology.stationIDs(line: lineCode, direction: direction)
        guard let index = stationIDs.firstIndex(of: stopID), index + 1 < stationIDs.count else {
            return nil
        }
        return stationIDs[index + 1]
    }

    /// A delay in seconds, which may be a number or a numeric string and may be
    /// negative (a train ahead of time). `JSONValue.int` drops the sign of a
    /// string, so this reads the value itself.
    private static func seconds(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let number = value as? Double { return Int(number) }
        if let text = value as? String {
            return Int(text.trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    /// GTFS-Realtime timestamps are unix seconds, published as strings.
    private static func timestamp(from value: Any?) -> Date? {
        if let seconds = JSONValue.double(from: value) {
            return Date(timeIntervalSince1970: seconds)
        }
        if let text = JSONValue.string(from: value), let seconds = Double(text) {
            return Date(timeIntervalSince1970: seconds)
        }
        return nil
    }
}
