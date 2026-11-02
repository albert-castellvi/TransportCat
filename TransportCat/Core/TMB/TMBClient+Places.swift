import Foundation

/// Place catalog endpoints of the TMB API (spec S2).
///
/// They travel through `TMBClient.get`, so they share its credentials, timeout
/// and error mapping. The all-network endpoints are preferred; the per-line
/// metro and bus feeds are only used where the network endpoint does not carry
/// the data the place model needs (accessibility, line membership).
extension TMBClient {
    /// Number of concurrent per-line requests while assembling the bus catalog.
    /// TMB serves one line per call, so a bounded fan-out keeps the launch load
    /// short without hammering the API.
    static let placeFanOut = 6

    // MARK: - Metro

    /// Every metro station of the network, grouped per line (spec S2).
    ///
    /// `/transit/estacions` (grouped stations) is the all-network endpoint, but
    /// its `EstacioGrup` payload has no accessibility field and its `PICTO` only
    /// names one line, while `Place` needs both the line codes and
    /// `accessible`. The per-line feed is therefore the only source that can
    /// fill the model for all 11 lines.
    ///
    /// One failed line fails the load: a catalog missing a whole line would look
    /// like the line had no stations, so the caller falls back to the cached
    /// copy instead.
    func metroPlaceLines() async throws -> [TMBPlaceMetroLine] {
        let lines = MetroLine.allLines
        let stationLists = try await withThrowingTaskGroup(
            of: (code: String, stations: [Station]).self
        ) { group in
            for line in lines {
                group.addTask {
                    (line.code, try await self.stations(lineCode: line.code))
                }
            }
            var byCode: [String: [Station]] = [:]
            for try await result in group {
                byCode[result.code] = result.stations
            }
            return lines.compactMap { line in
                byCode[line.code].map { (code: line.code, stations: $0) }
            }
        }

        return lines.compactMap { line in
            guard let stations = stationLists.first(where: { $0.code == line.code })?.stations else { return nil }
            return TMBPlaceMetroLine(code: line.code, displayName: line.displayName, stations: stations)
        }
    }

    // MARK: - Bus

    /// All TMB bus stops of the network (spec S2).
    /// GET /transit/parades (GeoJSON FeatureCollection)
    func busNetworkStops() async throws -> [TMBPlaceBusStop] {
        let data = try await get(path: "transit/parades")
        return try TMBPlaceParser.busNetworkStops(from: data)
    }

    /// Stops of every bus line, with its commercial name (spec S2).
    ///
    /// `/transit/parades` has no line membership, so the per-line feed is the
    /// only source for `Place.lineCodes`. A line that fails does not fail the
    /// catalog: its stops still appear from the network feed, just without that
    /// line, which is better than an empty bus map.
    func busPlaceLines(_ lines: [BusLine]) async throws -> [TMBPlaceBusLineStops] {
        var result: [TMBPlaceBusLineStops] = []
        let chunkSize = max(1, Self.placeFanOut)

        for start in stride(from: 0, to: lines.count, by: chunkSize) {
            let chunk = Array(lines[start..<min(start + chunkSize, lines.count)])
            let loaded = await withTaskGroup(
                of: (index: Int, value: TMBPlaceBusLineStops?).self
            ) { group in
                for (offset, line) in chunk.enumerated() {
                    group.addTask {
                        let stops = try? await self.busStops(lineCode: line.code)
                        return (offset, stops.map {
                            TMBPlaceBusLineStops(code: line.code, name: line.name, stops: $0)
                        })
                    }
                }
                var values: [(Int, TMBPlaceBusLineStops?)] = []
                for await value in group { values.append(value) }
                return values.sorted { $0.0 < $1.0 }
            }
            result.append(contentsOf: loaded.compactMap(\.1))
        }

        return result
    }
}
