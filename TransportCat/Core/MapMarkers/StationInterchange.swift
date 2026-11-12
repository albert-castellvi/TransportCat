import Foundation

/// Small grey icon next to a station with an active facility alert (spec S7,
/// D4): which station carries it and which kind of facility is out of service.
/// The map derives these when the topology or the alerts change, never on a
/// render.
struct FacilityStationMark: Equatable, Identifiable {
    /// `Station.code` the icon sits next to.
    let stationCode: Int
    let kind: IncidentKind
    let latitude: Double
    let longitude: Double

    var id: Int { stationCode }
}

/// Pure station iconography rules of the unified maps (spec S6, D4).
enum StationInterchange {
    /// Display names of the OTHER metro lines serving one station (D4): the
    /// input of the white interchange capsule. Metro–metro only, so bus and
    /// FGC codes in the catalog never produce a capsule.
    ///
    /// The place behind the station comes from the places catalog the same way
    /// `MapScreen` matches a `Place` focus: the catalog's `ID_ESTACIO` first,
    /// the folded name as the last resort. The per-line `CODI_ESTACIO` is never
    /// compared: it overlaps numerically with `ID_ESTACIO`, so a match on it
    /// would hand a station the lines of an unrelated place. Same-name metro
    /// places add their lines too — the two halves of a transfer are separate
    /// places whose merged line list the catalog also publishes, and the name
    /// match keeps the rule honest if it splits them again. Lines come out in
    /// `MetroLine.allLines` order, and the line on screen never names itself.
    static func metroLineDisplayNames(
        for station: Station,
        places: [Place],
        lineCode: String
    ) -> [String] {
        let needle = PlaceIndex.normalized(station.name)
        let matches = places.filter { place in
            guard place.kind == .metroStation else { return false }
            let sameCode = place.code == station.id.map { String($0) }
            let sameName = !needle.isEmpty && PlaceIndex.normalized(place.name) == needle
            return sameCode || sameName
        }
        guard !matches.isEmpty else { return [] }

        var seen: Set<String> = []
        var result: [String] = []
        for line in MetroLine.allLines {
            guard line.code != lineCode else { continue }
            for place in matches {
                let serves = place.lineCodes.contains { code in
                    code == line.code || code.caseInsensitiveCompare(line.displayName) == .orderedSame
                }
                if serves, seen.insert(line.code).inserted {
                    result.append(line.displayName)
                }
            }
        }
        return result
    }
}
