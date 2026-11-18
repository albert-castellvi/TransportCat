import Foundation

/// One label of the direction band above the Rodalies timeline: the arrow of
/// its travel direction and the terminus the rider reads.
struct RodaliesDirectionLabel: Equatable, Identifiable {
    /// 0 forward (drawn with "↓"), 1 reverse ("↑").
    let direction: Int
    /// Terminus name, full or abbreviated to fit the band.
    let name: String

    var id: Int { direction }

    /// "↓ Maçanet-Massanes" / "↑ L'Hospitalet de Llobregat": the arrow the
    /// band draws in front of the name.
    var text: String {
        (direction == 0 ? "↓ " : "↑ ") + name
    }
}

/// The direction band of the Rodalies timeline (spec B.3): each terminus is
/// named once above the list, in the direction the rail runs. Long pairs fall
/// back to the short station name ("Maçanet") before the band is allowed to
/// truncate with an ellipsis.
///
/// Pure: the caller passes the names the topology already has, and the answer
/// is the same for the same input, so the band is testable without a screen.
enum RodaliesDirectionLabels {
    /// Combined characters above which both names are shortened. At the card's
    /// width (~330 pt) and caption 12 pt bold, the R1 pair ("L'Hospitalet de
    /// Llobregat" + "Maçanet-Massanes") fits at 47; longer pairs do not.
    static let maxCharacters = 48

    /// One label per existing direction, in the order the caller lists them,
    /// skipping directions the topology has no name for. The full names are
    /// used while the pair fits `maxCharacters`; otherwise both are shortened.
    static func labels(names: [Int: String], order: [Int]) -> [RodaliesDirectionLabel] {
        let full = order.compactMap { direction -> RodaliesDirectionLabel? in
            guard let name = names[direction]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else { return nil }
            return RodaliesDirectionLabel(direction: direction, name: name)
        }
        guard full.count > 1 else { return full }
        // "↓ " / "↑ " in front of each name, plus the gap between the two.
        let characters = full.reduce(0) { partial, label in
            partial + label.name.count + 2
        } + 2
        guard characters > maxCharacters else { return full }
        return full.map { label in
            RodaliesDirectionLabel(direction: label.direction, name: shortName(label.name))
        }
    }

    /// The short name a band label falls back to: the first meaningful part of
    /// a compound station name ("Maçanet-Massanes" → "Maçanet",
    /// "L'Hospitalet de Llobregat" → "L'Hospitalet", "Vilanova i la Geltrú" →
    /// "Vilanova"). A name with nothing to drop is returned unchanged.
    static func shortName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let separators = [" i la ", " de la ", " del ", " de ", " - ", " – ", "-", ","]
        for separator in separators {
            guard let range = trimmed.range(of: separator) else { continue }
            let prefix = trimmed[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            if !prefix.isEmpty { return prefix }
        }
        return trimmed
    }
}

/// The other Rodalies lines that call at one station, ready for the capsule
/// row under its name: at most `limit` codes plus the count of the rest.
struct RodaliesLineBadges: Equatable {
    /// Codes to draw as capsules, in topology order.
    let codes: [String]
    /// Lines beyond the drawn capsules, shown as "+N".
    let overflow: Int

    var isEmpty: Bool { codes.isEmpty && overflow == 0 }
}

/// The interchange capsules of a Rodalies row (spec B.3): the station's own
/// `lineCodes` minus the line being shown, deduplicated, never more than three.
enum RodaliesStationBadges {
    /// Capsules drawn before the "+N" pill; the header band names the selected
    /// line, so it is never repeated on a row.
    static let maximum = 3

    static func badges(
        lineCodes: [String],
        shownLineCode: String,
        limit: Int = maximum
    ) -> RodaliesLineBadges {
        var seen: Set<String> = [shownLineCode]
        var codes: [String] = []
        for code in lineCodes {
            let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            codes.append(trimmed)
        }
        guard codes.count > limit else { return RodaliesLineBadges(codes: codes, overflow: 0) }
        return RodaliesLineBadges(
            codes: Array(codes.prefix(limit)),
            overflow: codes.count - limit
        )
    }
}

/// The live trains the feed places at one station, folded into the one marker
/// and the "+N" pill the row draws.
struct RodaliesStationTrainGroup: Equatable {
    /// All trains at the stop, in feed order (the sheet lists them).
    let trains: [RodaliesLiveTrain]
    /// The train the single marker belongs to: the first one.
    let marker: RodaliesLiveTrain?

    var count: Int { trains.count }

    /// "+N" once a station has more than one train, nil while the single
    /// marker is enough. N is the number of trains at the stop, which is also
    /// what the sheet lists.
    var pillText: String? {
        count >= 2 ? "+\(count)" : nil
    }
}

/// The train grouping of one station row. `trainsByStation` in the screen
/// keeps doing the keying; this only folds its list into "one marker plus a
/// count", so the second marker can never cover the station name.
enum RodaliesStationTrains {
    static func group(_ trains: [RodaliesLiveTrain]) -> RodaliesStationTrainGroup {
        RodaliesStationTrainGroup(trains: trains, marker: trains.first)
    }
}

// MARK: - Nearest station ("Ets aquí")

extension ParadesTimeline {
    /// Which Rodalies station of the line is nearest to `userLocation`, the
    /// same rule the metro timeline uses: smallest straight-line distance,
    /// ties broken by station id so the answer is deterministic. Nil when the
    /// rider has no fix or the line has no station.
    static func nearestStation(
        stations: [RodaliesStation],
        userLocation: GeoPoint?
    ) -> (station: RodaliesStation, distanceMeters: Double)? {
        guard let userLocation else { return nil }
        var best: (station: RodaliesStation, distanceMeters: Double)?
        for station in stations {
            let distance = GeoMath.distanceMeters(from: userLocation, to: station.point)
            if best == nil
                || distance < best!.distanceMeters
                || (distance == best!.distanceMeters && station.id < best!.station.id) {
                best = (station, distance)
            }
        }
        return best
    }
}
