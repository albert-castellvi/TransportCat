import XCTest
@testable import TransportCat

/// Pure formatting rules of the Explora tab (spec S12): the distance and
/// walking captions of "A prop" and the ranking of the line search. Everything
/// is deterministic: no clock, no locale lookup, no network.
final class ExploreFormattingTests: XCTestCase {
    // MARK: - Spec constants (S12)

    func testNearbyLimitsFollowTheSpec() {
        XCTAssertEqual(ExploreFormatting.nearbyLimit, 10)
        XCTAssertEqual(ExploreFormatting.nearbyRadiusMeters, 1_000)
        XCTAssertEqual(ExploreFormatting.walkingSpeedMetersPerMinute, 80)
        XCTAssertEqual(ExploreFormatting.arrivalsPerPlace, 2)
    }

    // MARK: - distanceText

    func testDistanceUnderAKilometerReadsInMeters() {
        XCTAssertEqual(ExploreFormatting.distanceText(meters: 0), "0 m")
        XCTAssertEqual(ExploreFormatting.distanceText(meters: 350), "350 m")
        XCTAssertEqual(ExploreFormatting.distanceText(meters: 999.4), "999 m")
    }

    func testDistanceRoundsWithOneDecimalInKilometers() {
        XCTAssertEqual(ExploreFormatting.distanceText(meters: 999.6), "1,0 km")
        XCTAssertEqual(ExploreFormatting.distanceText(meters: 1_000), "1,0 km")
        XCTAssertEqual(ExploreFormatting.distanceText(meters: 1_234), "1,2 km")
        XCTAssertEqual(ExploreFormatting.distanceText(meters: 1_250), "1,3 km")
        XCTAssertEqual(ExploreFormatting.distanceText(meters: 2_000), "2,0 km")
    }

    func testNegativeDistanceClampsToZero() {
        XCTAssertEqual(ExploreFormatting.distanceText(meters: -12), "0 m")
    }

    // MARK: - walkingMinutes

    func testWalkingMinutesRoundToNearestAtEightyMetersPerMinute() {
        XCTAssertEqual(ExploreFormatting.walkingMinutes(meters: 0), 0)
        // The spec example: 350 m at 80 m/min is 4.375, shown as 4.
        XCTAssertEqual(ExploreFormatting.walkingMinutes(meters: 350), 4)
        XCTAssertEqual(ExploreFormatting.walkingMinutes(meters: 320), 4)
        XCTAssertEqual(ExploreFormatting.walkingMinutes(meters: 1_000), 13)
    }

    func testAnyNonZeroDistanceWalksAtLeastOneMinute() {
        XCTAssertEqual(ExploreFormatting.walkingMinutes(meters: 1), 1)
        XCTAssertEqual(ExploreFormatting.walkingMinutes(meters: 39), 1)
        XCTAssertEqual(ExploreFormatting.walkingMinutes(meters: 80), 1)
        XCTAssertEqual(ExploreFormatting.walkingMinutes(meters: 120), 2)
    }

    func testNegativeDistanceWalksZeroMinutes() {
        XCTAssertEqual(ExploreFormatting.walkingMinutes(meters: -50), 0)
    }

    // MARK: - walkingText and the combined caption

    func testWalkingTextCarriesTheCatalanSuffix() {
        XCTAssertEqual(ExploreFormatting.walkingText(meters: 350), "4 min a peu")
        XCTAssertEqual(ExploreFormatting.walkingText(meters: 0), "0 min a peu")
    }

    func testNearbyCaptionJoinsDistanceAndWalkingTime() {
        XCTAssertEqual(ExploreFormatting.nearbyCaption(meters: 350), "350 m · 4 min a peu")
        XCTAssertEqual(ExploreFormatting.nearbyCaption(meters: 1_234), "1,2 km · 15 min a peu")
    }

    // MARK: - Line search ranking

    func testExactFoldedNameRanksFirst() {
        XCTAssertEqual(ExploreFormatting.bestLineRank(fields: ["L1", "1"], query: "l1"), 0)
        XCTAssertEqual(ExploreFormatting.bestLineRank(fields: ["S1"], query: " S1 "), 0)
    }

    func testPrefixRanksBeforeSubstring() {
        XCTAssertEqual(ExploreFormatting.bestLineRank(fields: ["L1", "1"], query: "L"), 1)
        XCTAssertEqual(ExploreFormatting.bestLineRank(fields: ["Diagonal Besòs", "12"], query: "bes"), 1)
        // "12" only sits inside "H12" and "212", so both are substring hits.
        XCTAssertEqual(ExploreFormatting.bestLineRank(fields: ["H12", "212"], query: "12"), 2)
    }

    func testDiacriticsAreFoldedInLineSearch() {
        // A folded word of the name starting with the query ranks as a prefix
        // hit, exactly like `PlaceIndex.search` does for places.
        XCTAssertEqual(ExploreFormatting.bestLineRank(fields: ["Tramvia Besòs"], query: "besos"), 1)
        XCTAssertEqual(ExploreFormatting.bestLineRank(fields: ["S1", "Barcelona – Vallès"], query: "valles"), 1)
    }

    func testNonMatchingQueryHasNoRank() {
        XCTAssertNil(ExploreFormatting.bestLineRank(fields: ["L1", "1"], query: "9"))
        XCTAssertNil(ExploreFormatting.bestLineRank(fields: ["H12"], query: ""))
        XCTAssertNil(ExploreFormatting.bestLineRank(fields: ["H12"], query: "   "))
        XCTAssertNil(ExploreFormatting.bestLineRank(fields: [], query: "L1"))
    }

    func testBestRankIsTheLowestAcrossFields() {
        // "9" is an exact code match even though it only sits inside "L9N".
        XCTAssertEqual(ExploreFormatting.bestLineRank(fields: ["L9N", "94"], query: "9"), 1)
        XCTAssertEqual(ExploreFormatting.bestLineRank(fields: ["L9N", "94"], query: "94"), 0)
    }
}
