import XCTest
@testable import TransportCat

/// Tests for the global map's zoom thresholds (spec S8).
///
/// The rule is pure and lives in `GlobalZoom`: wider than 0.25° draws only
/// lines; from 0.25° down to 0.08° stations join as dots; below 0.08° vehicles
/// and their labels join too. "Wider than" and "below" are strict, so the two
/// edges themselves (exactly 0.25 and exactly 0.08) belong to the station band.
final class GlobalZoomTests: XCTestCase {
    // MARK: - Lines only above 0.25°

    func testWideCameraDrawsOnlyLines() {
        XCTAssertEqual(GlobalZoom.level(forLatitudeSpan: 1.0), .lines)
        XCTAssertEqual(GlobalZoom.level(forLatitudeSpan: 0.26), .lines)
        let level = GlobalZoom.level(forLatitudeSpan: 0.3)
        XCTAssertFalse(level.includesStations)
        XCTAssertFalse(level.includesVehicles)
    }

    /// Just above the threshold is still the lines-only level; the edge itself
    /// is the station band, because "wider than 0.25°" excludes 0.25.
    func testLinesOnlyThresholdEdgeIsExclusive() {
        XCTAssertEqual(GlobalZoom.level(forLatitudeSpan: 0.2500001), .lines)
        XCTAssertEqual(GlobalZoom.level(forLatitudeSpan: 0.25), .linesAndStations)
    }

    // MARK: - Stations between 0.08° and 0.25°

    func testMiddleSpanAddsStationsButNoVehicles() {
        let level = GlobalZoom.level(forLatitudeSpan: 0.15)
        XCTAssertEqual(level, .linesAndStations)
        XCTAssertTrue(level.includesStations)
        XCTAssertFalse(level.includesVehicles)
    }

    /// The lower edge behaves like the upper one: "below 0.08°" excludes 0.08,
    /// so exactly 0.08 still draws the station band.
    func testStationBandLowerEdgeIsInclusive() {
        XCTAssertEqual(GlobalZoom.level(forLatitudeSpan: 0.08), .linesAndStations)
        XCTAssertEqual(GlobalZoom.level(forLatitudeSpan: 0.081), .linesAndStations)
    }

    // MARK: - Vehicles and labels below 0.08°

    func testCloseCameraAddsVehiclesAndLabels() {
        let level = GlobalZoom.level(forLatitudeSpan: 0.079)
        XCTAssertEqual(level, .linesStationsAndVehicles)
        XCTAssertTrue(level.includesStations)
        XCTAssertTrue(level.includesVehicles)
        XCTAssertEqual(GlobalZoom.level(forLatitudeSpan: 0.001), .linesStationsAndVehicles)
    }

    // MARK: - Monotonicity

    /// Zooming in never removes detail: walking from a wide span to a tight
    /// one only ever moves down the three levels.
    func testDetailOnlyGrowsAsTheSpanShrinks() {
        let spans = [2.0, 0.26, 0.25, 0.1, 0.08, 0.07, 0.0]
        let ranks = spans.map { GlobalZoom.rank(of: GlobalZoom.level(forLatitudeSpan: $0)) }
        for index in 1..<ranks.count {
            XCTAssertGreaterThanOrEqual(ranks[index], ranks[index - 1])
        }
    }
}

/// Tests for the `globalOperators` persistence codec (spec S8).
///
/// The operator chips store a comma-joined list of raw tokens; anything the
/// enum does not know is ignored, and the encoding writes the tokens in
/// `CaseIterable` order so a re-save is stable.
final class GlobalOperatorsTests: XCTestCase {
    func testDefaultRawSelectsEveryOperator() {
        XCTAssertEqual(
            GlobalOperatorSelection.decode(GlobalOperatorSelection.defaultRaw),
            Set(GlobalOperator.allCases)
        )
    }

    func testDecodeIgnoresUnknownAndEmptyTokens() {
        XCTAssertEqual(GlobalOperatorSelection.decode("metro,tram,fgc"), [.metro, .fgc])
        XCTAssertEqual(GlobalOperatorSelection.decode(" metro , bus ,, fgc "), [.metro, .bus, .fgc])
        XCTAssertEqual(GlobalOperatorSelection.decode(""), [])
        XCTAssertEqual(GlobalOperatorSelection.decode("metro,FBC"), [.metro])
    }

    func testEncodeWritesCanonicalOrderAndRoundTrips() {
        XCTAssertEqual(GlobalOperatorSelection.encode([.fgc, .metro]), "metro,fgc")
        XCTAssertEqual(GlobalOperatorSelection.encode([]), "")
        XCTAssertEqual(GlobalOperatorSelection.encode(Set(GlobalOperator.allCases)), "metro,bus,fgc")
        for raw in ["metro", "bus,fgc", "metro,bus,fgc"] {
            XCTAssertEqual(GlobalOperatorSelection.encode(GlobalOperatorSelection.decode(raw)), raw)
        }
    }
}
