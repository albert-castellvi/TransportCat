import XCTest
@testable import TransportCat

/// Tests for the metro map's station zoom bands (issue #93).
///
/// The rule is pure and lives in `MetroStationZoom`: wider than 0.25° of
/// visible latitude the stations are dots; at 0.25° and below the full
/// markers (interchange capsule or hollow dot) join. The calibration is the
/// camera the metro map fits: the whole-line view of a long line such as L1
/// lands around 0.36° of visible latitude on a portrait phone (the padded
/// longitude span fills the width), and a view of about six stations lands
/// around 0.10°.
final class MetroStationZoomTests: XCTestCase {
    // MARK: - Dots above 0.25°

    func testWideCameraDrawsDots() {
        // The whole-line fit of L1 (≈ 0.36° visible latitude).
        XCTAssertEqual(MetroStationZoom.band(forLatitudeSpan: 0.36), .dots)
        XCTAssertEqual(MetroStationZoom.band(forLatitudeSpan: 0.26), .dots)
    }

    /// The threshold edge is exclusive: "wider than 0.25°" excludes 0.25, so
    /// exactly 0.25 still draws the capsule band.
    func testDotsThresholdEdgeIsExclusive() {
        XCTAssertEqual(MetroStationZoom.band(forLatitudeSpan: 0.2500001), .dots)
        XCTAssertEqual(MetroStationZoom.band(forLatitudeSpan: 0.25), .capsules)
    }

    // MARK: - Capsules at 0.25° and below

    func testCloseCameraDrawsCapsules() {
        // A view of about six stations (≈ 0.10° visible latitude).
        XCTAssertEqual(MetroStationZoom.band(forLatitudeSpan: 0.10), .capsules)
        XCTAssertEqual(MetroStationZoom.band(forLatitudeSpan: 0.02), .capsules)
        XCTAssertEqual(MetroStationZoom.band(forLatitudeSpan: 0), .capsules)
    }

    // MARK: - Band hysteresis

    /// Inside the margin around the threshold the previous band wins, so a
    /// span wobbling there cannot rebuild the map content.
    func testHysteresisKeepsPreviousBandInsideTheMargin() {
        // 0.245 sits just under the threshold; the dot band holds.
        XCTAssertEqual(
            MetroStationZoom.band(forLatitudeSpan: 0.245, previous: .dots),
            .dots
        )
        // 0.255 sits just over the threshold; still the capsule band.
        XCTAssertEqual(
            MetroStationZoom.band(forLatitudeSpan: 0.255, previous: .capsules),
            .capsules
        )
    }

    /// Past the margin the band changes, in both directions.
    func testHysteresisFlipsPastTheMargin() {
        XCTAssertEqual(
            MetroStationZoom.band(forLatitudeSpan: 0.23, previous: .dots),
            .capsules
        )
        XCTAssertEqual(
            MetroStationZoom.band(forLatitudeSpan: 0.27, previous: .capsules),
            .dots
        )
    }

    /// The margin edges themselves flip: 0.24 (≤ dots exit) leaves the dot
    /// band and 0.26 (> capsule enter threshold) enters it.
    func testHysteresisMarginEdgesFlip() {
        XCTAssertEqual(
            MetroStationZoom.band(forLatitudeSpan: 0.24, previous: .dots),
            .capsules
        )
        XCTAssertEqual(
            MetroStationZoom.band(forLatitudeSpan: 0.26, previous: .capsules),
            .dots
        )
        XCTAssertEqual(
            MetroStationZoom.band(forLatitudeSpan: 0.2400001, previous: .dots),
            .dots
        )
    }

    /// Far from the threshold hysteresis is invisible: the result equals the
    /// plain threshold rule for every previous band.
    func testHysteresisEqualsTheThresholdRuleFarFromTheEdge() {
        let previousBands: [MetroStationBand] = [.dots, .capsules]
        for span in [1.0, 0.36, 0.10, 0.0] {
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
