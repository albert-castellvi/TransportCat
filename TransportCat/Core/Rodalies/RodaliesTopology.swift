import Foundation

/// The bundled static network of Rodalies de Catalunya: lines, stations and, per
/// line and direction, the ordered stations and the drawn track.
///
/// Built from Renfe's open GTFS by `scripts/build-rodalies-pack.py` and shipped
/// inside the app (it is small; only the timetable travels over the network).
/// Foundation only, so the widget and the watch can compile it as well.
struct RodaliesTopology: Equatable {
    /// Name of the bundled resource, without the extension.
    static let resourceName = "rodalies-topology"
    /// Only version 1 exists; an unknown version is not loaded.
    static let supportedVersion = 1

    /// Lines in the order the app should present them (R1, R2, R2N, R10...).
    let lines: [RodaliesLine]
    let stations: [RodaliesStation]
    let directions: [RodaliesDirection]

    // MARK: - Loading

    /// The topology bundled with the app, decoded once per process. Nil when
    /// the resource is missing (a build mistake) or unreadable.
    static let bundled: RodaliesTopology? = load()

    /// Reads the resource from `bundle` and decodes it.
    static func load(from bundle: Bundle = .main) -> RodaliesTopology? {
        guard let url = bundle.url(forResource: resourceName, withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return decode(data)
    }

    /// Decodes the topology payload, or nil when it is not one this code
    /// understands.
    static func decode(_ data: Data) -> RodaliesTopology? {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.v == supportedVersion else { return nil }
        return RodaliesTopology(
            lines: payload.lines,
            stations: payload.stations,
            directions: payload.directions
        )
    }

    private struct Payload: Decodable {
        let v: Int
        let lines: [RodaliesLine]
        let stations: [RodaliesStation]
        let directions: [RodaliesDirection]
    }

    // MARK: - Lookups

    func line(code: String) -> RodaliesLine? {
        lines.first { $0.code == code }
    }

    func station(id: String) -> RodaliesStation? {
        stations.first { $0.id == id }
    }

    /// The stations and track of one line and direction, nil when the line does
    /// not run that way in the feed.
    func direction(line: String, direction: Int) -> RodaliesDirection? {
        directions.first { $0.lineCode == line && $0.direction == direction }
    }

    /// Station ids of one line and direction in travel order.
    func stationIDs(line: String, direction: Int) -> [String] {
        self.direction(line: line, direction: direction)?.stationIDs ?? []
    }

    /// Lines that call at a station, in the topology's line order.
    func lines(at stationID: String) -> [RodaliesLine] {
        guard let station = station(id: stationID) else { return [] }
        return station.lineCodes.compactMap { line(code: $0) }
    }

    /// Every station of one line, forward direction first, without duplicates.
    func stations(ofLine code: String) -> [RodaliesStation] {
        var seen: Set<String> = []
        var result: [RodaliesStation] = []
        for direction in 0...1 {
            for stationID in stationIDs(line: code, direction: direction) where seen.insert(stationID).inserted {
                if let station = station(id: stationID) {
                    result.append(station)
                }
            }
        }
        return result
    }
}
