import XCTest
@testable import TransportCat

/// The pure rules of the Rodalies stops list: the direction band's labels, the
/// other-line capsules, the one-marker-plus-"N" folding of the trains at a
/// station, and the nearest-station rule behind "Ets aquí". No UI and no
/// network, so every rule can be pinned here.
final class RodaliesListModelTests: XCTestCase {
    // MARK: - Direction band

    /// R1's own pair fits: the band keeps the full terminus names.
    func testTheR1PairKeepsItsFullNames() {
        let labels = RodaliesDirectionLabels.labels(
            names: [
                0: "L'Hospitalet de Llobregat",
                1: "Maçanet-Massanes",
            ],
            order: [0, 1]
        )
        XCTAssertEqual(labels.map(\.direction), [0, 1])
        XCTAssertEqual(
            labels.map(\.name),
            ["L'Hospitalet de Llobregat", "Maçanet-Massanes"]
        )
        XCTAssertEqual(labels[0].text, "↓ L'Hospitalet de Llobregat")
        XCTAssertEqual(labels[1].text, "↑ Maçanet-Massanes")
    }

    /// A pair too long for the band is abbreviated to the short station name
    /// before it is allowed to truncate with an ellipsis.
    func testALongPairFallsBackToTheShortNames() {
        let labels = RodaliesDirectionLabels.labels(
            names: [
                0: "Barcelona Plaça de Catalunya",
                1: "Sant Vicenç de Calders",
            ],
            order: [0, 1]
        )
        XCTAssertEqual(labels.map(\.name), ["Barcelona Plaça", "Sant Vicenç"])
    }

    /// A line with one published direction shows that one name, never an empty
    /// label for the direction the feed does not run.
    func testASingleDirectionKeepsItsName() {
        let labels = RodaliesDirectionLabels.labels(
            names: [0: "Barcelona Plaça de Catalunya"],
            order: [0]
        )
        XCTAssertEqual(labels, [RodaliesDirectionLabel(
            direction: 0,
            name: "Barcelona Plaça de Catalunya"
        )])
    }

    /// Directions the topology has no name for are skipped instead of drawing
    /// an arrow with nothing after it.
    func testMissingDirectionNamesAreSkipped() {
        let labels = RodaliesDirectionLabels.labels(
            names: [0: "Ocata", 1: "   "],
            order: [0, 1]
        )
        XCTAssertEqual(labels.map(\.direction), [0])
        XCTAssertEqual(labels.map(\.name), ["Ocata"])
    }

    /// The short name is the first meaningful part of a compound station name.
    func testShortNameDropsTheCompounds() {
        XCTAssertEqual(
            RodaliesDirectionLabels.shortName("Maçanet-Massanes"),
            "Maçanet"
        )
        XCTAssertEqual(
            RodaliesDirectionLabels.shortName("L'Hospitalet de Llobregat"),
            "L'Hospitalet"
        )
        XCTAssertEqual(
            RodaliesDirectionLabels.shortName("Sant Vicenç de Calders"),
            "Sant Vicenç"
        )
        XCTAssertEqual(
            RodaliesDirectionLabels.shortName("Vilanova i la Geltrú"),
            "Vilanova"
        )
        XCTAssertEqual(
            RodaliesDirectionLabels.shortName("Barcelona - Sants"),
            "Barcelona"
        )
        XCTAssertEqual(
            RodaliesDirectionLabels.shortName("Barcelona-Sants"),
            "Barcelona"
        )
        XCTAssertEqual(RodaliesDirectionLabels.shortName("Ocata"), "Ocata")
    }

    // MARK: - Other-line capsules

    /// The selected line never appears on its own rows; the rest keep topology
    /// order and duplicates are dropped.
    func testBadgesDropTheShownLineAndDuplicates() {
        let badges = RodaliesStationBadges.badges(
            lineCodes: ["R1", "R2", "R4", "R2"],
            shownLineCode: "R1"
        )
        XCTAssertEqual(badges.codes, ["R2", "R4"])
        XCTAssertEqual(badges.overflow, 0)
        XCTAssertFalse(badges.isEmpty)
    }

    /// Three capsules, then "+N" for the rest.
    func testBadgesCapAtThreeAndCountTheRest() {
        let badges = RodaliesStationBadges.badges(
            lineCodes: ["R1", "R2", "R3", "R4", "R7"],
            shownLineCode: "R1"
        )
        XCTAssertEqual(badges.codes, ["R2", "R3", "R4"])
        XCTAssertEqual(badges.overflow, 1)
    }

    /// A station served only by the shown line draws no capsule row.
    func testBadgesAreEmptyWhenNoOtherLineServesTheStation() {
        let badges = RodaliesStationBadges.badges(
            lineCodes: ["R1"],
            shownLineCode: "R1"
        )
        XCTAssertTrue(badges.isEmpty)
        XCTAssertEqual(badges.codes, [])
        XCTAssertEqual(badges.overflow, 0)
    }

    /// Blank codes are not a line and never become a capsule.
    func testBlankCodesAreIgnored() {
        let badges = RodaliesStationBadges.badges(
            lineCodes: ["", "  ", "R2"],
            shownLineCode: "R1"
        )
        XCTAssertEqual(badges.codes, ["R2"])
    }

    /// The caller can ask for a smaller capsule row (the row label reads the
    /// full list with a high limit instead).
    func testTheCapsuleLimitIsTheCallersChoice() {
        let badges = RodaliesStationBadges.badges(
            lineCodes: ["R1", "R2", "R3", "R4"],
            shownLineCode: "R1",
            limit: 1
        )
        XCTAssertEqual(badges.codes, ["R2"])
        XCTAssertEqual(badges.overflow, 2)
    }

    // MARK: - Trains at a station

    func testNoTrainAtTheStationHasNoMarkerAndNoPill() {
        let group = RodaliesStationTrains.group([])
        XCTAssertEqual(group.count, 0)
        XCTAssertNil(group.marker)
        XCTAssertNil(group.pillText)
    }

    /// One train keeps the single marker and draws no pill.
    func testOneTrainKeepsTheSingleMarker() {
        let group = RodaliesStationTrains.group([train("18122")])
        XCTAssertEqual(group.count, 1)
        XCTAssertEqual(group.marker?.id, "18122")
        XCTAssertNil(group.pillText)
    }

    /// Several trains fold into the first marker plus "+N"; the sheet lists
    /// every train in feed order.
    func testSeveralTrainsBecomeOneMarkerAndAPill() {
        let trains = [train("18122"), train("18130"), train("18140")]
        let group = RodaliesStationTrains.group(trains)
        XCTAssertEqual(group.count, 3)
        XCTAssertEqual(group.marker?.id, "18122")
        XCTAssertEqual(group.pillText, "+3")
        XCTAssertEqual(group.trains.map(\.id), ["18122", "18130", "18140"])
    }

    // MARK: - Nearest station ("Ets aquí")

    func testNearestStationIsTheClosestOne() {
        let stations = [
            station(id: "1", latitude: 41.0, longitude: 2.0),
            station(id: "2", latitude: 41.02, longitude: 2.02),
        ]
        let nearest = ParadesTimeline.nearestStation(
            stations: stations,
            userLocation: GeoPoint(latitude: 41.001, longitude: 2.001)
        )
        XCTAssertEqual(nearest?.station.id, "1")
    }

    /// Ties are broken by station id, so the highlighted row never flickers
    /// between two stations at the same point.
    func testNearestStationBreaksTiesByStationID() {
        let stations = [
            station(id: "2", latitude: 41.0, longitude: 2.0),
            station(id: "1", latitude: 41.0, longitude: 2.0),
        ]
        let nearest = ParadesTimeline.nearestStation(
            stations: stations,
            userLocation: GeoPoint(latitude: 41.0, longitude: 2.0)
        )
        XCTAssertEqual(nearest?.station.id, "1")
    }

    func testNearestStationWithoutAFixOrStationsIsNil() {
        XCTAssertNil(ParadesTimeline.nearestStation(stations: [] as [RodaliesStation], userLocation: nil))
        XCTAssertNil(ParadesTimeline.nearestStation(
            stations: [station(id: "1", latitude: 41.0, longitude: 2.0)],
            userLocation: nil
        ))
        XCTAssertNil(ParadesTimeline.nearestStation(stations: [] as [RodaliesStation], userLocation: GeoPoint(
            latitude: 41.0,
            longitude: 2.0
        )))
    }

    // MARK: - Fixtures

    private func station(
        id: String,
        latitude: Double,
        longitude: Double,
        lines: [String] = ["R1"]
    ) -> RodaliesStation {
        RodaliesStation(
            id: id,
            name: "Estació \(id)",
            latitude: latitude,
            longitude: longitude,
            lineCodes: lines,
            wheelchairBoarding: nil
        )
    }

    private func train(_ id: String) -> RodaliesLiveTrain {
        RodaliesLiveTrain(
            id: id,
            lineCode: "R1",
            direction: 0,
            headsign: "Maçanet-Massanes",
            position: GeoPoint(latitude: 41.0, longitude: 2.0),
            bearingDegrees: nil,
            delaySeconds: 120,
            timestamp: nil,
            currentStopID: "71801",
            nextStopID: nil,
            status: "STOPPED_AT"
        )
    }
}
