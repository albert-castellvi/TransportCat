import XCTest
@testable import TransportCat

/// The global map's line-state bookkeeping (#27).
///
/// `GlobalNetworkState` is a session singleton, so a line whose topology load
/// failed (or was cancelled while leaving the map) can only recover if the
/// next visit knows which lines still have no stations. The rule is pure over
/// the published station counts, which is what these tests pin.
@MainActor
final class GlobalNetworkStateTests: XCTestCase {
    func testEveryLineWithoutAStateNeedsItsTopologyLoaded() {
        let pending = GlobalNetworkState.linesNeedingTopologyLoad(stationCounts: [:])

        XCTAssertEqual(pending.map(\.code), MetroLine.allLines.map(\.code))
    }

    func testLoadedLinesAreLeftAlone() {
        let allLines = MetroLine.allLines
        // Every line loaded, the first one with a single station (the smallest
        // successful load).
        let stationCounts = Dictionary(uniqueKeysWithValues: allLines.map { ($0.code, 12) })
        XCTAssertTrue(GlobalNetworkState.linesNeedingTopologyLoad(stationCounts: stationCounts).isEmpty)
    }

    /// The failure the issue describes: a cold start whose stations request
    /// failed leaves `stations == []` for that line only, and that line must
    /// be rebuilt on the next visit while its siblings keep their state.
    func testALineThatLoadedNothingIsRetried() {
        let allLines = MetroLine.allLines
        let failedLine = allLines[2]
        var stationCounts = Dictionary(uniqueKeysWithValues: allLines.map { ($0.code, 12) })
        stationCounts[failedLine.code] = 0

        let pending = GlobalNetworkState.linesNeedingTopologyLoad(stationCounts: stationCounts)

        XCTAssertEqual(pending.map(\.code), [failedLine.code])
    }
}
