import XCTest
import CoreGraphics
@testable import TransportCat

/// Pure layout math of the Parades timelines (`ParadesRowGeometry`, UX-26):
/// the planned-minimum-vs-measured-height rule and the vehicle y both the row
/// rendering and the vehicle overlays agree on, so rows and markers cannot
/// drift apart when a row grows past its planned minimum.
final class ParadesRowGeometryTests: XCTestCase {
    // MARK: - Row height

    func testRowHeightFallsBackToPlannedWhenNotMeasured() {
        XCTAssertEqual(
            ParadesRowGeometry.rowHeight(planned: 64, measured: nil),
            64,
            accuracy: 0.001
        )
    }

    func testRowHeightPrefersMeasured() {
        XCTAssertEqual(
            ParadesRowGeometry.rowHeight(planned: 64, measured: 92),
            92,
            accuracy: 0.001
        )
    }

    // MARK: - Cumulative tops

    func testTopsUsePlannedMinimaWhenNothingMeasured() {
        let tops = ParadesRowGeometry.tops(planned: [64, 64, 64], measured: [:])
        XCTAssertEqual(tops, [0, 64, 128])
    }

    func testTopsUsePlannedBusMinimaWithIncidentLines() {
        // Bus plan: base 66 plus one 18 pt incident line on the middle row.
        let tops = ParadesRowGeometry.tops(planned: [66, 84, 66], measured: [:])
        XCTAssertEqual(tops, [0, 66, 150])
    }

    func testTopsUseMeasuredHeightsWhereKnown() {
        // Only the middle row grew; its neighbours sit at its real edges.
        let tops = ParadesRowGeometry.tops(planned: [64, 64, 64], measured: [1: 92])
        XCTAssertEqual(tops, [0, 64, 156])
    }

    func testTopsOfEmptyPlanAreEmpty() {
        XCTAssertTrue(ParadesRowGeometry.tops(planned: [], measured: [:]).isEmpty)
    }

    // MARK: - Vehicle y

    /// The planned heights and tops the y assertions below read.
    private var plannedHeights: [CGFloat] { [64, 64, 64] }
    private var plannedTops: [CGFloat] { [0, 64, 128] }

    func testVehicleYAtAStationIsItsRowMarkerCenter() {
        let y = ParadesRowGeometry.vehicleY(
            tops: plannedTops,
            heights: plannedHeights,
            position: 1
        )
        // Marker center of row 1: 64 + 32.
        XCTAssertEqual(y ?? -1, 96, accuracy: 0.001)
    }

    func testVehicleYFractionLandsInsideItsRow() {
        let y = ParadesRowGeometry.vehicleY(
            tops: plannedTops,
            heights: plannedHeights,
            position: 0.5
        )
        // Halfway between the markers of row 0 (32) and row 1 (96).
        XCTAssertEqual(y ?? -1, 64, accuracy: 0.001)
    }

    func testVehicleYUsesMeasuredHeightOfTheRowItLandsOn() {
        let planned = plannedHeights
        let tops = ParadesRowGeometry.tops(planned: planned, measured: [1: 92])
        let heights = planned.enumerated().map { index, plannedHeight in
            ParadesRowGeometry.rowHeight(planned: plannedHeight, measured: measuredHeight(index, in: [1: 92]))
        }
        let y = ParadesRowGeometry.vehicleY(tops: tops, heights: heights, position: 1)
        // Marker center of the grown row 1: 64 + 46.
        XCTAssertEqual(y ?? -1, 110, accuracy: 0.001)
    }

    func testVehicleYClampsBeyondLastRow() {
        let y = ParadesRowGeometry.vehicleY(
            tops: plannedTops,
            heights: plannedHeights,
            position: 3.5
        )
        // Last row's own marker, never one row past it.
        XCTAssertEqual(y ?? -1, 160, accuracy: 0.001)
    }

    func testVehicleYClampsBeforeFirstRow() {
        let y = ParadesRowGeometry.vehicleY(
            tops: plannedTops,
            heights: plannedHeights,
            position: -1
        )
        XCTAssertEqual(y ?? -1, 32, accuracy: 0.001)
    }

    func testVehicleYReturnsNilWithoutRows() {
        XCTAssertNil(ParadesRowGeometry.vehicleY(tops: [], heights: [], position: 0))
    }

    // MARK: - Helpers

    private func measuredHeight(_ index: Int, in measured: [Int: CGFloat]) -> CGFloat? {
        measured[index]
    }
}
