import XCTest
@testable import TransportCat

/// Tests for the Tot incident grouping rule (spec S7, decision D6):
/// one badge per affected line at that line's first affected station — the
/// first one in the line's own station order when the line state provides it,
/// feed order otherwise — with the badges that land on the same station merged
/// into one. Only service alerts produce badges; facility alerts never show
/// in Tot.
///
/// Every expected value is computed from the real implementation inputs: the
/// line display names come from `MetroLine.line(forCode:)`, the memberwise
/// fixtures follow the declared field order of `GlobalIncidentStation` and
/// `ServiceAlert`, and the order lookup mirrors what the map reads from
/// `GlobalNetworkState.shared.lineStates[lineCode]?.stations`.
final class GlobalIncidentBadgesTests: XCTestCase {
    // MARK: - Fixtures

    /// A metro stop order, as a loaded line state would publish its stations:
    /// line code to (station code, `orderInLine`) in line order.
    private typealias LineOrder = [String: [(code: Int, orderInLine: Int)]]

    /// The order lookup the map passes into the helper.
    private func orderLookup(_ order: LineOrder) -> (String, Int) -> Int? {
        { lineCode, stationCode in
            order[lineCode]?.first { $0.code == stationCode }?.orderInLine
        }
    }

    private func station(
        id: String,
        code: Int,
        name: String,
        latitude: Double,
        longitude: Double,
        alerts: [ServiceAlert]
    ) -> GlobalIncidentStation {
        GlobalIncidentStation(
            id: id,
            stationCode: code,
            name: name,
            position: GeoPoint(latitude: latitude, longitude: longitude),
            alerts: alerts
        )
    }

    private func serviceAlert(
        id: String,
        lineCodes: [String]
    ) -> ServiceAlert {
        ServiceAlert(
            id: id,
            lineCodes: lineCodes,
            stationNames: [],
            beginDate: nil,
            endDate: nil,
            text: nil,
            effectType: "TRAFFIC"
        )
    }

    private func facilityAlert(
        id: String,
        lineCodes: [String]
    ) -> ServiceAlert {
        ServiceAlert(
            id: id,
            lineCodes: lineCodes,
            stationNames: [],
            beginDate: nil,
            endDate: nil,
            text: nil,
            effectType: "INFRASTRUCTURE"
        )
    }

    private func lineName(_ code: String) -> String {
        MetroLine.line(forCode: code)?.displayName ?? code
    }

    // MARK: - One badge per affected line

    /// Two affected lines whose first affected stations differ produce two
    /// badges, each showing the line's display name and carrying exactly the
    /// service alerts that affect it.
    func testOneBadgePerAffectedLine() {
        let l1Alert = serviceAlert(id: "a1", lineCodes: ["1"])
        let l5Alert = serviceAlert(id: "a2", lineCodes: ["5"])
        let stations = [
            station(id: "metro:1", code: 1, name: "Catalunya", latitude: 41.387, longitude: 2.169, alerts: [l1Alert]),
            station(id: "metro:2", code: 2, name: "Sagrada Família", latitude: 41.403, longitude: 2.174, alerts: [l5Alert]),
        ]
        let badges = GlobalIncidentBadges.badges(from: stations, orderOfStation: orderLookup([:]))

        XCTAssertEqual(badges.count, 2)
        let l1Badge = badges.first { $0.lineNames == [lineName("1")] }
        let l5Badge = badges.first { $0.lineNames == [lineName("5")] }
        XCTAssertNotNil(l1Badge)
        XCTAssertNotNil(l5Badge)
        // Feed order: Catalunya sits before Sagrada Família in the input.
        XCTAssertEqual(badges.first?.lineNames, [lineName("1")])
        XCTAssertEqual(l1Badge?.badgeText, lineName("1"))
        XCTAssertEqual(l1Badge?.stationCode, 1)
        XCTAssertEqual(l1Badge?.stationName, "Catalunya")
        XCTAssertEqual(l1Badge?.position, GeoPoint(latitude: 41.387, longitude: 2.169))
        XCTAssertEqual(l1Badge?.alerts.map(\.id), ["a1"])
        XCTAssertEqual(l5Badge?.stationCode, 2)
        XCTAssertEqual(l5Badge?.alerts.map(\.id), ["a2"])
        // The badge identity is the station the badge sits on.
        XCTAssertEqual(l1Badge?.id, "metro:1")
    }

    /// One alert covering several lines puts every affected line on the map;
    /// when they share their first affected station the badges merge into the
    /// grouped count.
    func testOneAlertCoveringTwoLinesProducesOneGroupedBadge() {
        let alert = serviceAlert(id: "a1", lineCodes: ["1", "5"])
        let stations = [
            station(id: "metro:1", code: 1, name: "Catalunya", latitude: 41.387, longitude: 2.169, alerts: [alert]),
        ]
        let badges = GlobalIncidentBadges.badges(from: stations, orderOfStation: orderLookup([:]))

        XCTAssertEqual(badges.count, 1)
        XCTAssertEqual(badges.first?.lineNames, [lineName("1"), lineName("5")])
        XCTAssertEqual(badges.first?.badgeText, "2 línies")
        XCTAssertEqual(badges.first?.alerts.map(\.id), ["a1"])
    }

    // MARK: - Placement follows the line's own station order

    /// The first affected station is the one earliest in the LINE's own
    /// station order, not the one first in the feed: an alert listed at two
    /// stations places the badge at the line's first station even when the
    /// feed lists the other one first.
    func testPlacementFollowsOrderInLine() throws {
        let alert = serviceAlert(id: "a1", lineCodes: ["2"])
        // Feed order lists Vergós first (higher line order), Poblenou second.
        let stations = [
            station(id: "metro:20", code: 20, name: "Virrei Amat", latitude: 41.421, longitude: 2.17, alerts: [alert]),
            station(id: "metro:21", code: 21, name: "Poblenou", latitude: 41.415, longitude: 2.19, alerts: [alert]),
        ]
        let order: LineOrder = ["2": [(code: 21, orderInLine: 0), (code: 20, orderInLine: 1)]]
        let badges = GlobalIncidentBadges.badges(from: stations, orderOfStation: orderLookup(order))

        XCTAssertEqual(badges.count, 1)
        let badge = try XCTUnwrap(badges.first)
        XCTAssertEqual(badge.stationCode, 21)
        XCTAssertEqual(badge.stationName, "Poblenou")
        XCTAssertEqual(badge.id, "metro:21")
        XCTAssertEqual(badge.lineNames, [lineName("2")])
        XCTAssertEqual(badge.badgeText, lineName("2"))
        XCTAssertEqual(badge.alerts.map(\.id), ["a1"])
    }

    /// Without line order data (the line state not loaded yet) the badge sits
    /// at the first affected station in feed order.
    func testMissingOrderFallsBackToFeedOrder() {
        let alert = serviceAlert(id: "a1", lineCodes: ["2"])
        let stations = [
            station(id: "metro:20", code: 20, name: "Virrei Amat", latitude: 41.421, longitude: 2.17, alerts: [alert]),
            station(id: "metro:21", code: 21, name: "Poblenou", latitude: 41.415, longitude: 2.19, alerts: [alert]),
        ]
        let badges = GlobalIncidentBadges.badges(from: stations, orderOfStation: orderLookup([:]))

        XCTAssertEqual(badges.count, 1)
        XCTAssertEqual(badges.first?.stationCode, 20)
        XCTAssertEqual(badges.first?.stationName, "Virrei Amat")
    }

    // MARK: - Badges on the same station merge

    /// Two lines whose first affected station is the same one merge into a
    /// single badge whose text is the grouped count; every line's service
    /// alerts join the card list, deduplicated by alert identity.
    func testBadgesOnSameStationMerge() {
        // Each line is affected at both stations; the line orders place the
        // first affected station of BOTH lines at Catalunya.
        let l1Catalunya = serviceAlert(id: "a1", lineCodes: ["1"])
        let l1Sagrada = serviceAlert(id: "a1b", lineCodes: ["1"])
        let l5Catalunya = serviceAlert(id: "a2", lineCodes: ["5"])
        let l5Sagrada = serviceAlert(id: "a2b", lineCodes: ["5"])
        let l1Facility = facilityAlert(id: "a3", lineCodes: ["1"])
        let stations = [
            station(id: "metro:1", code: 1, name: "Catalunya", latitude: 41.387, longitude: 2.169, alerts: [l1Catalunya, l1Facility, l5Catalunya]),
            station(id: "metro:2", code: 2, name: "Sagrada Família", latitude: 41.403, longitude: 2.174, alerts: [l1Sagrada, l5Sagrada]),
        ]
        let order: LineOrder = [
            "1": [(code: 1, orderInLine: 3), (code: 2, orderInLine: 7)],
            "5": [(code: 1, orderInLine: 2), (code: 2, orderInLine: 9)],
        ]
        let badges = GlobalIncidentBadges.badges(from: stations, orderOfStation: orderLookup(order))

        XCTAssertEqual(badges.count, 1)
        let badge = badges[0]
        XCTAssertEqual(badge.stationCode, 1)
        XCTAssertEqual(badge.stationName, "Catalunya")
        XCTAssertEqual(badge.id, "metro:1")
        XCTAssertEqual(badge.lineNames, [lineName("1"), lineName("5")])
        XCTAssertEqual(badge.badgeText, "2 línies")
        // The facility alert never joins the badge: only the two service
        // alerts of the station, in feed order.
        XCTAssertEqual(badge.alerts.map(\.id), ["a1", "a2"])
    }

    /// The same alert can back two lines of one merged badge; the alert list
    /// keeps it once.
    func testSharedAlertInMergedBadgeIsDeduplicated() {
        let shared = serviceAlert(id: "a1", lineCodes: ["1", "5"])
        let stations = [
            station(id: "metro:1", code: 1, name: "Catalunya", latitude: 41.387, longitude: 2.169, alerts: [shared]),
        ]
        let badges = GlobalIncidentBadges.badges(from: stations, orderOfStation: orderLookup([:]))

        XCTAssertEqual(badges.count, 1)
        XCTAssertEqual(badges.first?.badgeText, "2 línies")
        XCTAssertEqual(badges.first?.alerts.map(\.id), ["a1"])
    }

    /// Three lines on one station read "3 línies", and the grouped count of
    /// two stations on the same line never merges: a line's badge sits at one
    /// station only.
    func testThreeLinesReadTheGroupedCount() {
        let alert = serviceAlert(id: "a1", lineCodes: ["1", "5", "2"])
        let stations = [
            station(id: "metro:1", code: 1, name: "Catalunya", latitude: 41.387, longitude: 2.169, alerts: [alert]),
        ]
        let badges = GlobalIncidentBadges.badges(from: stations, orderOfStation: orderLookup([:]))

        XCTAssertEqual(badges.count, 1)
        XCTAssertEqual(badges.first?.badgeText, "3 línies")
        XCTAssertEqual(badges.first?.lineNames.count, 3)
    }

    // MARK: - Facility alerts never show in Tot

    /// A station whose only alerts are facility ones produces no badge, and a
    /// mixed station keeps only the service alerts.
    func testFacilityOnlyAlertsProduceNoBadge() {
        let facility = facilityAlert(id: "a1", lineCodes: ["1"])
        let mixedService = serviceAlert(id: "a2", lineCodes: ["5"])
        let mixedFacility = facilityAlert(id: "a3", lineCodes: ["5"])
        let stations = [
            station(id: "metro:1", code: 1, name: "Verdaguer", latitude: 41.393, longitude: 2.152, alerts: [facility]),
            station(id: "metro:2", code: 2, name: "Sagrada Família", latitude: 41.403, longitude: 2.174, alerts: [mixedService, mixedFacility]),
        ]
        let badges = GlobalIncidentBadges.badges(from: stations, orderOfStation: orderLookup([:]))

        XCTAssertEqual(badges.count, 1)
        XCTAssertEqual(badges.first?.lineNames, [lineName("5")])
        XCTAssertEqual(badges.first?.badgeText, lineName("5"))
        XCTAssertEqual(badges.first?.alerts.map(\.id), ["a2"])
    }

    // MARK: - Empty input

    func testEmptyInputProducesNoBadges() {
        XCTAssertTrue(GlobalIncidentBadges.badges(from: [], orderOfStation: orderLookup([:])).isEmpty)
    }

    /// A station with no service alert at all — the state `refreshIncidents`
    /// publishes when only facilities cover it — produces no badge either.
    func testStationWithoutAlertsProducesNoBadge() {
        let stations = [
            station(id: "metro:1", code: 1, name: "Catalunya", latitude: 41.387, longitude: 2.169, alerts: []),
        ]
        XCTAssertTrue(GlobalIncidentBadges.badges(from: stations, orderOfStation: orderLookup([:])).isEmpty)
    }

    /// An alert whose line codes list is empty never produces a badge.
    func testAlertWithoutLineCodesProducesNoBadge() {
        let alert = serviceAlert(id: "a1", lineCodes: [])
        let stations = [
            station(id: "metro:1", code: 1, name: "Catalunya", latitude: 41.387, longitude: 2.169, alerts: [alert]),
        ]
        XCTAssertTrue(GlobalIncidentBadges.badges(from: stations, orderOfStation: orderLookup([:])).isEmpty)
    }
}
