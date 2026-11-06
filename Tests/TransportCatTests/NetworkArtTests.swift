import CoreGraphics
import XCTest
@testable import TransportCat

/// Tests for the network motif's pure logic (spec S11): the scaling of the
/// 390×300 mockup design space, the partial-polyline trim used to draw the
/// lines in, the looping animation phases, and the Avisos empty-state
/// decision (`AlertsStateSummary`).
final class NetworkArtTests: XCTestCase {
    // MARK: - Scaling

    func testScaleFitsWithinBothDimensions() {
        XCTAssertEqual(NetworkArtGeometry.scale(in: CGSize(width: 390, height: 300)), 1, accuracy: 1e-12)
        // Limited by the height.
        XCTAssertEqual(NetworkArtGeometry.scale(in: CGSize(width: 780, height: 300)), 1, accuracy: 1e-12)
        // Limited by the width.
        XCTAssertEqual(NetworkArtGeometry.scale(in: CGSize(width: 390, height: 600)), 1, accuracy: 1e-12)
        // Halves.
        XCTAssertEqual(NetworkArtGeometry.scale(in: CGSize(width: 195, height: 150)), 0.5, accuracy: 1e-12)
    }

    func testScaleRejectsInvalidSizes() {
        XCTAssertEqual(NetworkArtGeometry.scale(in: CGSize(width: 0, height: 300)), 0)
        XCTAssertEqual(NetworkArtGeometry.scale(in: CGSize(width: 390, height: 0)), 0)
    }

    func testFittedOriginCentersTheArt() {
        // 780×300 at scale 1 leaves 390 spare points, half on each side.
        let origin = NetworkArtGeometry.fittedOrigin(in: CGSize(width: 780, height: 300))
        XCTAssertEqual(origin.x, 195, accuracy: 1e-12)
        XCTAssertEqual(origin.y, 0, accuracy: 1e-12)
    }

    // MARK: - Geometry shape

    /// The network stays octilinear: every segment is horizontal, vertical or
    /// at 45 degrees, like the icon.
    func testAllSegmentsAreOctilinear() {
        for line in NetworkArtGeometry.lines {
            XCTAssertGreaterThanOrEqual(line.points.count, 2)
            for i in 1..<line.points.count {
                let dx = abs(line.points[i].x - line.points[i - 1].x)
                let dy = abs(line.points[i].y - line.points[i - 1].y)
                let horizontal = dx > 0 && dy == 0
                let vertical = dy > 0 && dx == 0
                let diagonal = dx > 0 && dy > 0 && abs(dx - dy) < 1e-9
                XCTAssertTrue(horizontal || vertical || diagonal, "Segment \(i) of a line is not octilinear")
            }
        }
        // The icon keeps five lines, one per colour.
        XCTAssertEqual(NetworkArtGeometry.lines.count, 5)
        XCTAssertEqual(Set(NetworkArtGeometry.lineHexes).count, 5)
    }

    /// Each terminal ring sits on one of its line's endpoints.
    func testTerminalRingsSitOnLineEndpoints() {
        for terminal in NetworkArtGeometry.terminals {
            let line = NetworkArtGeometry.lines[terminal.lineIndex]
            let isStart = line.points.first == terminal.point
            let isEnd = line.points.last == terminal.point
            XCTAssertTrue(isStart || isEnd, "Terminal ring is not on its line's end")
        }
    }

    // MARK: - Partial polyline (trim)

    func testPartialDegenerateInputs() {
        XCTAssertEqual(NetworkArtGeometry.partial([], fraction: 0.5), [])
        let only = [CGPoint(x: 3, y: 4)]
        XCTAssertEqual(NetworkArtGeometry.partial(only, fraction: 0.5), only)
    }

    func testPartialClampsFraction() {
        let line = [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)]
        XCTAssertEqual(NetworkArtGeometry.partial(line, fraction: -0.5), [line[0]])
        XCTAssertEqual(NetworkArtGeometry.partial(line, fraction: 1.5), line)
    }

    func testPartialMidpointOfASingleSegment() {
        let line = [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)]
        let half = NetworkArtGeometry.partial(line, fraction: 0.5)
        XCTAssertEqual(half.count, 2)
        XCTAssertEqual(half.last!.x, 50, accuracy: 1e-9)
        XCTAssertEqual(half.last!.y, 0, accuracy: 1e-9)
    }

    func testPartialAcrossTwoSegments() {
        let line = [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 100)]
        // Total length 200: 62.5 % of it is 25 units into the second segment,
        // so the node (100, 0) is included once, not twice.
        let cut = NetworkArtGeometry.partial(line, fraction: 0.625)
        XCTAssertEqual(cut.count, 3)
        XCTAssertEqual(cut[1].x, 100, accuracy: 1e-9)
        XCTAssertEqual(cut[1].y, 0, accuracy: 1e-9)
        XCTAssertEqual(cut[2].x, 100, accuracy: 1e-9)
        XCTAssertEqual(cut[2].y, 25, accuracy: 1e-9)
    }

    func testPartialAtSegmentBoundaryHasNoDuplicateNode() {
        let line = [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 100)]
        let cut = NetworkArtGeometry.partial(line, fraction: 0.5)
        XCTAssertEqual(cut, [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)])
    }

    // MARK: - Loop phase

    func testLoopPhaseWrapsAroundThePeriod() {
        XCTAssertEqual(NetworkArtGeometry.loopPhase(of: 0, period: 3.2), 0, accuracy: 1e-9)
        XCTAssertEqual(NetworkArtGeometry.loopPhase(of: 1.6, period: 3.2), 0.5, accuracy: 1e-9)
        XCTAssertEqual(NetworkArtGeometry.loopPhase(of: 6.4, period: 3.2), 0, accuracy: 1e-9)
        XCTAssertEqual(NetworkArtGeometry.loopPhase(of: 2.75, period: 1), 0.75, accuracy: 1e-9)
    }

    func testLoopPhaseIsAlwaysNonNegative() {
        XCTAssertEqual(NetworkArtGeometry.loopPhase(of: -0.1, period: 3.2), 3.1 / 3.2, accuracy: 1e-9)
    }

    // MARK: - Easing

    func testEasedEndpointsAndMidpoint() {
        XCTAssertEqual(NetworkArtGeometry.eased(0), 0, accuracy: 1e-12)
        XCTAssertEqual(NetworkArtGeometry.eased(1), 1, accuracy: 1e-12)
        XCTAssertEqual(NetworkArtGeometry.eased(0.5), 0.5, accuracy: 1e-12)
    }

    func testEasedIsSymmetric() {
        XCTAssertEqual(NetworkArtGeometry.eased(0.25), 0.0625, accuracy: 1e-12)
        XCTAssertEqual(NetworkArtGeometry.eased(0.75), 1 - 0.0625, accuracy: 1e-12)
    }

    // MARK: - Line transitions (the drawing loop)

    func testLineIsHiddenBeforeItsDelay() {
        // Line 1 starts 0.12 s into a 3.2 s cycle. Building the phase from the
        // same constants keeps the comparison exact.
        let delay = NetworkArtGeometry.lineDelayStep / NetworkArtGeometry.drawingPeriod
        let transition = NetworkArtGeometry.lineTransition(delay, index: 1)
        XCTAssertEqual(transition.trim, 0, accuracy: 1e-12)
        XCTAssertEqual(transition.alpha, 0, accuracy: 1e-12)
    }

    func testLineDrawsInDuringItsWindow() {
        // Phase 0.2 of the period for line 0 (no delay): 0.2 / 0.45 of the
        // draw window is left, eased.
        let transition = NetworkArtGeometry.lineTransition(0.2, index: 0)
        XCTAssertEqual(transition.trim, NetworkArtGeometry.eased(0.2 / 0.45), accuracy: 1e-12)
        XCTAssertEqual(transition.alpha, 1, accuracy: 1e-12)
    }

    func testLineHoldsThenFadesOut() {
        let holding = NetworkArtGeometry.lineTransition(0.6, index: 0)
        XCTAssertEqual(holding.trim, 1, accuracy: 1e-12)
        XCTAssertEqual(holding.alpha, 1, accuracy: 1e-12)

        // Fading starts at 0.85 of the cycle: at 0.9, a third of the fade is
        // gone.
        let fading = NetworkArtGeometry.lineTransition(0.9, index: 0)
        XCTAssertEqual(fading.trim, 1, accuracy: 1e-12)
        XCTAssertEqual(fading.alpha, 2 / 3, accuracy: 1e-9)
    }

    // MARK: - Ring transitions (the pop-in loop)

    func testRingIsHiddenBeforeItsDelay() {
        // The first ring starts 0.5 s into a 3.2 s cycle: 0.15625 of it.
        let transition = NetworkArtGeometry.ringTransition(0.15625, index: 0)
        XCTAssertEqual(transition.alpha, 0, accuracy: 1e-12)
    }

    func testRingPopsIn() {
        // Halfway through the pop window: halfway in size and opacity.
        let delay = NetworkArtGeometry.ringFirstDelay / NetworkArtGeometry.drawingPeriod
        let halfway = delay + (NetworkArtGeometry.popStart + NetworkArtGeometry.popEnd) / 2
        let transition = NetworkArtGeometry.ringTransition(halfway, index: 0)
        XCTAssertEqual(transition.alpha, 0.5, accuracy: 1e-12)
        XCTAssertEqual(transition.scale, 0.65, accuracy: 1e-12)
    }

    func testRingHoldsThenFadesOut() {
        let delay = NetworkArtGeometry.ringFirstDelay / NetworkArtGeometry.drawingPeriod
        let holding = NetworkArtGeometry.ringTransition(delay + 0.6, index: 0)
        XCTAssertEqual(holding.scale, 1, accuracy: 1e-12)
        XCTAssertEqual(holding.alpha, 1, accuracy: 1e-12)

        let fading = NetworkArtGeometry.ringTransition(delay + 0.9, index: 0)
        XCTAssertEqual(fading.alpha, 2 / 3, accuracy: 1e-9)
    }

    // MARK: - Avisos empty state (AlertsStateSummary)

    private func alert(id: String, effectType: String?) -> ServiceAlert {
        var alert = ServiceAlert(
            id: id,
            lineCodes: ["2"],
            stationNames: [],
            beginDate: nil,
            endDate: nil,
            text: nil
        )
        alert.effectType = effectType
        return alert
    }

    private var service: ServiceAlert { alert(id: "s", effectType: "TRAFFIC") }
    private var facility: ServiceAlert { alert(id: "f", effectType: "INFRASTRUCTURE") }

    func testEmptyFeedShowsEmptyState() {
        let summary = AlertsStateSummary(alerts: [])
        XCTAssertTrue(summary.showsEmptyState)
        XCTAssertEqual(summary.facilityCount, 0)
    }

    func testServiceOnlyFeedHidesEmptyState() {
        let summary = AlertsStateSummary(alerts: [service, service])
        XCTAssertFalse(summary.showsEmptyState)
        XCTAssertEqual(summary.facilityCount, 0)
    }

    func testFacilityOnlyFeedStillShowsEmptyState() {
        let summary = AlertsStateSummary(alerts: [facility, facility, facility])
        XCTAssertTrue(summary.showsEmptyState)
        XCTAssertEqual(summary.facilityCount, 3)
    }

    func testMixedFeedKeepsBothGroupsInFeedOrder() {
        let first = facility
        let second = service
        let third = facility
        let summary = AlertsStateSummary(alerts: [first, second, third])
        XCTAssertFalse(summary.showsEmptyState)
        XCTAssertEqual(summary.serviceAlerts, [second])
        XCTAssertEqual(summary.facilityAlerts, [first, third])
    }

    func testFacilityTitleCopy() {
        XCTAssertEqual(AlertsStateSummary.facilityTitle(count: 3), "3 instal·lacions fora de servei")
        XCTAssertEqual(AlertsStateSummary.facilityTitle(count: 1), "1 instal·lació fora de servei")
        XCTAssertEqual(AlertsStateSummary.facilityTitle(count: 0), "0 instal·lacions fora de servei")
        XCTAssertEqual(AlertsStateSummary.facilitySubtitle, "No afecten la circulació")
    }
}
