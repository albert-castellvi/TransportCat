import SwiftUI

/// Conversions between `Place` and the operator models the detail sheets take,
/// in both directions (spec S12). The rules mirror `TMBPlaceParser`: the metro
/// code is `station.id ?? station.code`, the bus code is `stop.code`, FGC uses
/// the station initials, and `lineCodes` always hold display names.
enum ExplorePlaceBridge {
    // MARK: - Model → Place (the star toggles inside the sheets)

    @MainActor
    static func place(for station: Station, line: MetroLine) -> Place {
        let bridged = Place(
            kind: .metroStation,
            code: String(station.id ?? station.code),
            name: station.name,
            position: GeoPoint(latitude: station.latitude, longitude: station.longitude),
            lineCodes: [line.displayName],
            accessible: station.accessible
        )
        // The catalog place with the same id carries every line serving the
        // station; starring the bridged one-line place would freeze the
        // favorite to the line it was opened from (spec S12).
        return PlaceCatalogStore.shared.place(id: bridged.id) ?? bridged
    }

    static func place(for stop: BusStop, line: BusLine) -> Place {
        Place(
            kind: .busStop,
            code: String(stop.code),
            name: stop.name,
            position: GeoPoint(latitude: stop.latitude, longitude: stop.longitude),
            lineCodes: [line.name],
            accessible: nil
        )
    }

    // MARK: - Place → models (the sheets Explore presents)

    /// A synthetic `Station` for the metro sheet. `orderInLine` and the route
    /// fields are irrelevant there: `StationDetailView` only reads the code,
    /// the name, the coordinates and the accessibility flag.
    static func station(for place: Place) -> Station {
        Station(
            code: Int(place.code) ?? 0,
            name: place.name,
            orderInLine: 0,
            lineCode: metroLine(for: place).code,
            latitude: place.position.latitude,
            longitude: place.position.longitude,
            id: Int(place.code),
            accessible: place.accessible
        )
    }

    /// The first of the place's lines whose display name or code matches a
    /// catalog line; L1 when a place somehow lists no known line.
    static func metroLine(for place: Place) -> MetroLine {
        for code in place.lineCodes {
            if let line = MetroLine.allLines.first(where: {
                $0.code == code || $0.displayName.caseInsensitiveCompare(code) == .orderedSame
            }) {
                return line
            }
        }
        return MetroLine.allLines[0]
    }

    /// A `BusStop` for `BusStopSheet`: the physical stop as the catalog knows
    /// it. The address row shows the lines serving the stop, which is what a
    /// place knows about it.
    static func busStop(for place: Place) -> BusStop {
        BusStop(
            code: Int(place.code) ?? 0,
            name: place.name,
            address: place.lineCodes.joined(separator: " · "),
            order: 0,
            directionID: 1,
            directionName: "",
            destinationName: "",
            distanceFromPrevious: 0,
            latitude: place.position.latitude,
            longitude: place.position.longitude,
            routeID: 0
        )
    }

    /// The catalog line behind the sheet's colors, or a neutral stand-in when
    /// the catalog has not loaded yet (the sheet only reads colors and names).
    @MainActor
    static func busLine(for place: Place) -> BusLine {
        if let line = BusCatalogStore.shared.lines.first(where: { line in
            place.lineCodes.contains { $0.caseInsensitiveCompare(line.name) == .orderedSame }
        }) {
            return line
        }
        return BusLine(
            code: Int(place.lineCodes.first ?? "") ?? 0,
            name: place.lineCodes.first ?? "Bus",
            description: "",
            origin: "",
            destination: "",
            colorHex: "6B7280",
            textColorHex: "FFFFFF",
            familyCode: 0,
            familyName: "",
            familyOrder: 0,
            order: 0
        )
    }
}

/// The place detail of a search or favorites result (spec S12): the metro
/// sheet, the bus stop sheet or the FGC station sheet, each closed by the
/// operator's own "Tancar", plus the shared "Veure al mapa" bar that sends the
/// rider to the map focused on this place.
@MainActor
struct ExplorePlaceDetailSheet: View {
    let place: Place

    /// Bus alerts of the line the stop belongs to, exactly as the bus map and
    /// the bus diagram read them (spec S7).
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            switch place.kind {
            case .metroStation:
                StationDetailView(
                    station: ExplorePlaceBridge.station(for: place),
                    line: ExplorePlaceBridge.metroLine(for: place)
                )
                .safeAreaInset(edge: .bottom, spacing: 0) { mapLinkBar }
            case .busStop:
                let stop = ExplorePlaceBridge.busStop(for: place)
                let line = ExplorePlaceBridge.busLine(for: place)
                BusStopSheet(
                    stop: stop,
                    line: line,
                    incidents: incidents(for: stop, line: line)
                )
                .safeAreaInset(edge: .bottom, spacing: 0) { mapLinkBar }
            case .fgcStation:
                FGCStationSheet(place: place)
                    .safeAreaInset(edge: .bottom, spacing: 0) { mapLinkBar }
            }
        }
    }

    /// Incidents of one stop, derived the way `BusDiagramScreen` derives them:
    /// from the active alerts already in the model, for the line the stop was
    /// opened under. A literal empty list hid every disruption of a stop
    /// reached from Explore (bug #61).
    private func incidents(for stop: BusStop, line: BusLine) -> [StationIncident] {
        let lineCode = String(line.code)
        return IncidentIndex.incidents(
            for: app.activeBusAlerts(affecting: lineCode),
            stations: [stop.asStation(lineCode: lineCode)],
            lineCode: lineCode
        )[stop.code] ?? []
    }

    /// "Veure al mapa": closes the sheet and asks the router to focus the map
    /// on this place (spec S5, S11).
    private var mapLinkBar: some View {
        Button {
            dismiss()
            AppRouter.shared.open(.place(place))
        } label: {
            Label("Veure al mapa", systemImage: "map.fill")
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(.bar)
    }
}
