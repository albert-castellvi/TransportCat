import Foundation

/// Accessibility type of one station access, folded from TMB's
/// `NOM_TIPUS_ACCESSIBILITAT` (spec S17).
enum TMBAccessKind: Hashable {
    case accessible
    case partiallyAccessible
    case notAccessible
    /// The feed said nothing TMB-wide understood, or the access is in a state
    /// ("En obres") that makes the type meaningless today.
    case unknown

    /// Reads the human-readable type case- and diacritic-insensitively. A text
    /// this does not know stays `unknown`: claiming accessibility from a
    /// wording accident is worse than admitting the feed is silent.
    init(accessibilityText: String?) {
        let folded = accessibilityText.map(PlaceIndex.normalized) ?? ""
        if folded.contains("no accessible") {
            self = .notAccessible
        } else if folded.contains("parcial") {
            self = .partiallyAccessible
        } else if folded == "accessible" {
            self = .accessible
        } else {
            self = .unknown
        }
    }

    /// Catalan label of the type, shown and read next to the access name.
    var label: String {
        switch self {
        case .accessible:
            return "Accessible"
        case .partiallyAccessible:
            return "Parcialment accessible"
        case .notAccessible:
            return "No accessible"
        case .unknown:
            return "Sense informació"
        }
    }
}

/// One physical entrance of a metro station, with its accessibility type
/// (spec S17).
struct TMBStationAccess: Hashable, Identifiable {
    /// TMB `CODI_ACCES`, nil when the feed does not carry it.
    let code: Int?
    /// `NOM_ACCES`, e.g. "Rambla de Bellvitge".
    let name: String
    let kind: TMBAccessKind

    var id: String { "\(code.map(String.init) ?? "x")-\(name)" }
}

/// Pure parsing of the metro accesses feed (spec S17): the GeoJSON documented
/// as `LlistaAccessos` behind `GET /transit/estacions/{codi_grup_estacio}/accessos`
/// (`DOC-TMB/transit.json`, definition `Acces`).
///
/// Foundation-only like every other parser here, so the tolerance rules run in
/// the Linux harness without a network.
enum TMBAccessParser {
    /// `CODI_GRUP_ESTACIO` = `CODI_ESTACIO` + this offset. Evidence: every
    /// feature of the real L1 station feed (111→6660111, 112→6660112,
    /// 113→6660113 in `Fixtures/stations-L1.json`) and the API documentation
    /// examples (`CodiEstacio` 210 with `CodiGrupEstacio` 6660210, and the
    /// `Acces` example 6660315 for Palau Reial, station 315). The accesses
    /// endpoint is keyed by the group code, which the app's `Station` model
    /// does not carry, so the offset is the only bridge between the two.
    static let groupCodeOffset = 6_660_000

    /// The station-group code the access endpoint wants for a `CODI_ESTACIO`.
    static func groupStationCode(forStationCode stationCode: Int) -> Int {
        stationCode + groupCodeOffset
    }

    /// The station's accesses, in feed order. A feature without a name is
    /// skipped: a row the rider cannot point at is noise.
    static func accesses(from data: Data) throws -> [TMBStationAccess] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let features = JSONValue.array(from: root["features"]) else {
            throw TMBError.unexpectedPayload("missing access features")
        }
        return features.compactMap { element in
            guard let properties = JSONValue.dictionary(from: JSONValue.dictionary(from: element)?["properties"]),
                  let name = JSONValue.string(from: properties["NOM_ACCES"]),
                  !name.isEmpty else {
                return nil
            }
            return TMBStationAccess(
                code: JSONValue.int(from: properties["CODI_ACCES"]),
                name: name,
                kind: TMBAccessKind(accessibilityText: JSONValue.string(from: properties["NOM_TIPUS_ACCESSIBILITAT"]))
            )
        }
    }
}
