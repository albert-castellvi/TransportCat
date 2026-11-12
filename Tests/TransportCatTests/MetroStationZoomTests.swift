import XCTest
@testable import TransportCat

/// Tests for the metro map's station zoom bands (issue #93).
///
/// The rule is pure and lives in `MetroStationZoom`: wider than 0.12° of
/// visible latitude the stations are dots; at 0.12° and below the full
/// markers (interchange capsule or hollow dot) join. The calibration comes
/// from a simulator measurement (iPhone 17 Pro, portrait): the whole-line
/// view of a long line such as L1 lands around 0.22° of visible latitude,
/// and a view of about six stations lands around 0.10°.
final class MetroStationZoomTests: XCTestCase {
    // MARK: - Dots above 0.12°

    func testWideCameraDrawsDots() {
        // The measured whole-line fit of L1 (≈ 0.22° visible latitude).
        XCTAssertEqual(MetroStationZoom.band(forLatitudeSpan: 0.22), .dots)
        XCTAssertEqual(MetroStationZoom.band(forLatitudeSpan: 0.13), .dots)
    }

    /// The threshold edge is exclusive: "wider than 0.12°" excludes 0.12, so
    /// exactly 0.12 still draws the capsule band.
    func testDotsThresholdEdgeIsExclusive() {
        XCTAssertEqual(MetroStationZoom.band(forLatitudeSpan: 0.1200001), .dots)
        XCTAssertEqual(MetroStationZoom.band(forLatitudeSpan: 0.12), .capsules)
    }

    // MARK: - Capsules at 0.12° and below

    func testCloseCameraDrawsCapsules() {
        // A view of about six stations (≈ 0.10° visible latitude).
        XCTAssertEqual(MetroStationZoom.band(forLatitudeSpan: 0.10), .capsules)
        XCTAssertEqual(MetroStationZoom.band(forLatitudeSpan: 0.02), .capsules)
        XCTAssertEqual(MetroStationZoom.band(forLatitudeSpan: 0), .capsules)
    }

    // MARK: - Band hysteresis

    /// Inside the margin around the threshold the previous band wins, so a
    /// span wobbling there cannot rebuild the map content. The gates sit at
    /// 0.12 × 0.96 ≈ 0.1152 (dot exit) and 0.12 × 1.04 ≈ 0.1248 (capsule
    /// enter); the sample values here keep clear of both.
    func testHysteresisKeepsPreviousBandInsideTheMargin() {
        // 0.116 sits just under the threshold; the dot band holds.
        XCTAssertEqual(
            MetroStationZoom.band(forLatitudeSpan: 0.116, previous: .dots),
            .dots
        )
        // 0.124 sits just over the threshold; still the capsule band.
        XCTAssertEqual(
            MetroStationZoom.band(forLatitudeSpan: 0.124, previous: .capsules),
            .capsules
        )
    }

    /// Past the margin the band changes, in both directions.
    func testHysteresisFlipsPastTheMargin() {
        XCTAssertEqual(
            MetroStationZoom.band(forLatitudeSpan: 0.11, previous: .dots),
            .capsules
        )
        XCTAssertEqual(
            MetroStationZoom.band(forLatitudeSpan: 0.13, previous: .capsules),
            .dots
        )
    }

    /// The margin edges themselves flip: past the dot exit the capsule band
    /// takes over, past the capsule enter threshold the dot band does.
    func testHysteresisMarginEdgesFlip() {
        XCTAssertEqual(
            MetroStationZoom.band(forLatitudeSpan: 0.115, previous: .dots),
            .capsules
        )
        XCTAssertEqual(
            MetroStationZoom.band(forLatitudeSpan: 0.125, previous: .capsules),
            .dots
        )
        XCTAssertEqual(
            MetroStationZoom.band(forLatitudeSpan: 0.116, previous: .dots),
            .dots
        )
    }

    /// Far from the threshold hysteresis is invisible: the result equals the
    /// plain threshold rule for every previous band.
    func testHysteresisEqualsTheThresholdRuleFarFromTheEdge() {
        let previousBands: [MetroStationBand] = [.dots, .capsules]
        for span in [1.0, 0.22, 0.10, 0.0] {
            let expected = MetroStationZoom.band(forLatitudeSpan: span)
            for previous in previousBands {
                XCTAssertEqual(
                    MetroStationZoom.band(forLatitudeSpan: span, previous: previous),
                    expected,
                    "span \(span) from \(previous) should match the plain rule"
                )
            }
        }
    }
}
