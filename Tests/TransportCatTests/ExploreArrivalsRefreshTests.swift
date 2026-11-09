import XCTest
@testable import TransportCat

/// Tests for the serialization of the favorites' arrivals refreshes (spec S12).
///
/// The Explora screen refreshes its favorite arrivals from the 30 s loop and
/// from the star toggle. Both passes are away in their network calls at the
/// same time, so the rule the rows rely on is: the newest pass owns the
/// snapshot, and an older one must not write when it finishes later.
final class ExploreArrivalsRefreshTests: XCTestCase {
    /// Starring a favorite starts a pass while the loop is mid-flight: the loop
    /// keeps its own answer instead of overwriting the newer snapshot, which is
    /// what shows "Sense arribades ara mateix" for a place that has arrivals.
    func testANewerPassTakesOwnershipFromTheRunningOne() {
        var generation = ArrivalRefreshGeneration()
        XCTAssertEqual(generation.current, 0)

        let loopPass = generation.begin()
        let starPass = generation.begin()

        XCTAssertFalse(generation.isCurrent(loopPass), "The older pass must discard its answer")
        XCTAssertTrue(generation.isCurrent(starPass))
    }

    /// A pass owns the snapshot from the moment it begins until a newer one
    /// does, and stale generations stay stale.
    func testAPassOwnsTheSnapshotUntilANewerOneBegins() {
        var generation = ArrivalRefreshGeneration()
        let first = generation.begin()
        XCTAssertTrue(generation.isCurrent(first))
        XCTAssertFalse(generation.isCurrent(first + 1))
        XCTAssertFalse(generation.isCurrent(0))

        _ = generation.begin()
        XCTAssertFalse(generation.isCurrent(first))
    }
}
