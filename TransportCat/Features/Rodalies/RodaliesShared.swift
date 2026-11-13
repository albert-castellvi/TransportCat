import SwiftUI

/// Which Rodalies line the map and the Parades timeline show.
///
/// The selection is the `@AppStorage("rodaliesSelectedLine")` key the two
/// screens, the accessory's chip and `AppRouter` all read and write, so the chip,
/// the map and the station list can never disagree about the line.
enum RodaliesLineSelection {
    /// The key every Rodalies surface persists the line under.
    static let storageKey = "rodaliesSelectedLine"
    /// The line the app opens with. R1 is the coast line through Barcelona,
    /// the busiest of the nucleus, so it is the most useful first screen.
    static let defaultLineCode = "R1"

    /// The code actually shown for a stored one: the stored code when it names
    /// a line, otherwise the first line, otherwise the stored code itself
    /// (nothing to choose yet).
    static func resolve(selected code: String, from lines: [RodaliesLine]) -> String {
        lines.first { $0.code == code }?.code ?? lines.first?.code ?? code
    }
}

/// The Rodalies lines the chrome can present before the mode has ever loaded
/// its state.
///
/// The topology ships inside the app, so the chip and the picker do not have to
/// wait for a poll to know the 19 lines: the state's copy wins when it exists
/// (it is the same data), and the bundled topology answers otherwise.
@MainActor
enum RodaliesLines {
    static var presented: [RodaliesLine] {
        let loaded = RodaliesNetworkState.shared.lines
        if !loaded.isEmpty { return loaded }
        return RodaliesTopology.bundled?.lines ?? []
    }
}

/// The `Place` a Rodalies station is searched, starred and routed as.
///
/// The catalog copy is preferred, exactly as `ExplorePlaceBridge` does for the
/// other operators: it carries every line that calls at the station, so a
/// favourite is not frozen to the line it was opened from.
@MainActor
enum RodaliesPlaces {
    static func place(for station: RodaliesStation) -> Place {
        let bridged = Place(
            kind: .rodaliesStation,
            code: station.id,
            name: station.name,
            position: station.point,
            lineCodes: station.lineCodes,
            accessible: station.isAccessible
        )
        return PlaceCatalogStore.shared.place(id: bridged.id) ?? bridged
    }
}

/// Line badge of the Rodalies screens in the line's own colours, the same
/// capsule the map's chips and the other operators' rows draw.
struct RodaliesLineBadge: View {
    let code: String
    let colorHex: String
    let textColorHex: String
    @ScaledMetric(relativeTo: .caption2) private var codeSize: CGFloat = 12

    var body: some View {
        Text(code)
            .font(.system(size: codeSize, weight: .bold))
            .foregroundStyle(Color(hex: textColorHex))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color(hex: colorHex)))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Línia \(code)")
    }
}
