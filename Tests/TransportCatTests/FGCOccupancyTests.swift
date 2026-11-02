import XCTest
@testable import TransportCat

/// Thresholds of the FGC occupancy summary (spec S18). Written before the
/// implementation: a mean below 40 % is "Ocupació baixa", 40–70 inclusive is
/// "Ocupació mitjana", above 70 is "Ocupació alta", and a feed without any
/// reported car yields nil so the badge and the accessibility label omit the
/// summary.
final class FGCOccupancyTests: XCTestCase {
    func testNoDataHasNoSummary() {
        XCTAssertNil(FGCOccupancy.summary([]))
        XCTAssertNil(FGCOccupancy.summary([nil]))
        XCTAssertNil(FGCOccupancy.summary([nil, nil, nil]))
    }

    func testLowOccupancyIsUnderForty() {
        XCTAssertEqual(FGCOccupancy.summary([0]), "Ocupació baixa")
        XCTAssertEqual(FGCOccupancy.summary([10]), "Ocupació baixa")
        XCTAssertEqual(FGCOccupancy.summary([39]), "Ocupació baixa")
    }

    func testMediumOccupancyIncludesBothBoundaries() {
        XCTAssertEqual(FGCOccupancy.summary([40]), "Ocupació mitjana")
        XCTAssertEqual(FGCOccupancy.summary([55]), "Ocupació mitjana")
        XCTAssertEqual(FGCOccupancy.summary([70]), "Ocupació mitjana")
    }

    func testHighOccupancyIsOverSeventy() {
        XCTAssertEqual(FGCOccupancy.summary([71]), "Ocupació alta")
        XCTAssertEqual(FGCOccupancy.summary([100]), "Ocupació alta")
    }

    func testMeanUsesOnlyTheReportedCars() {
        // 50 and 20 reported over two cars is a mean of 35: the unreported
        // cars do not drag the mean anywhere.
        XCTAssertEqual(FGCOccupancy.summary([50, nil, 20]), "Ocupació baixa")
        // 70 and 80 average 75: above the medium ceiling.
        XCTAssertEqual(FGCOccupancy.summary([70, 80]), "Ocupació alta")
        // 39 and 41 average exactly 40: the low bound of medium.
        XCTAssertEqual(FGCOccupancy.summary([39, 41]), "Ocupació mitjana")
    }
}
