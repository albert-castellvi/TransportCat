import Foundation

/// Station access endpoints of the TMB API (spec S17).
///
/// They travel through `TMBClient.get`, so they share its credentials, timeout
/// and error mapping. A failed fetch is the sheet's business: it hides the
/// "Accessos" section instead of showing a rider a wrong entrance.
extension TMBClient {
    /// The named entrances of one metro station, keyed by the TMB station-group
    /// code (`CODI_GRUP_ESTACIO`).
    /// GET /transit/estacions/{codi_grup_estacio}/accessos (`LlistaAccessos`)
    func stationAccesses(groupStationCode: Int) async throws -> [TMBStationAccess] {
        let data = try await get(path: "transit/estacions/\(groupStationCode)/accessos")
        return try TMBAccessParser.accesses(from: data)
    }

    /// The same for a per-line station code (`CODI_ESTACIO`), bridged by the
    /// group-code offset documented in `TMBAccessParser`.
    func stationAccesses(forStationCode stationCode: Int) async throws -> [TMBStationAccess] {
        try await stationAccesses(groupStationCode: TMBAccessParser.groupStationCode(forStationCode: stationCode))
    }
}
