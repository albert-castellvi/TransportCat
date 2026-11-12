import XCTest
@testable import TransportCat

/// #96: the planner publishes a line description as `route` for some bus
/// legs. A badge must carry a short code, never "Districte Gran Via ...".
final class PlannerLegBadgeTests: XCTestCase {
    func testBadgeKeepsShortCodesAndResolvesLongRouteDescriptions() {
        let description = "Districte Gran Via l'Hospitalet / Av. Esplugues"

        XCTAssertEqual(leg(route: "V1", mode: "BUS").badgeText, "V1")
        XCTAssertEqual(leg(route: nil, mode: "SUBWAY").badgeText, "Metro")
        // A description never fits a badge; the mode is the honest fallback.
        XCTAssertEqual(leg(route: description, mode: "BUS").badgeText, "Bus")
        // The bus catalog resolves that description to the commercial name.
        XCTAssertEqual(PlannerFormat.shortLineName(for: description, in: [v1()]), "V1")
        XCTAssertNil(PlannerFormat.shortLineName(for: "H12", in: [v1()]))
    }

    private func v1() -> BusLine {
        BusLine(
            code: 1,
            name: "V1",
            description: "Districte Gran Via l'Hospitalet / Av. Esplugues",
            origin: "Districte Gran Via l'Hospitalet",
            destination: "Av. Esplugues",
            colorHex: "6AB023",
            textColorHex: "0B2A00",
            familyCode: 1,
            familyName: "Verticals",
            familyOrder: 1,
            order: 1
        )
    }

    private func leg(route: String?, mode: String) -> Leg {
        Leg(
            startTime: Date(timeIntervalSince1970: 0),
            endTime: Date(timeIntervalSince1970: 120),
            mode: mode,
            route: route,
            routeLongName: nil,
            routeColorHex: nil,
            routeTextColorHex: nil,
            headsign: nil,
            agencyName: nil,
            distance: nil,
            from: LegPlace(name: "Origen", position: GeoPoint(latitude: 41.38, longitude: 2.16)),
            to: LegPlace(name: "Destinació", position: GeoPoint(latitude: 41.39, longitude: 2.17)),
            intermediateStops: [],
            geometry: [],
            isTransit: true
        )
    }
}
