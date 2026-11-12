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

    /// One physical station has a different per-line code on each line, so the
    /// global map keys it by a line-independent identity: the group code when
    /// present, else the normalized name plus the rounded position.
    func testStationGroupKeyIsLineIndependent() {
        func station(_ code: Int, id: Int, groupCode: Int?, lat: Double, lon: Double) -> Station {
            Station(
                code: code,
                name: "Catalunya",
                orderInLine: 1,
                lineCode: code == 128 ? "1" : "3",
                latitude: lat,
                longitude: lon,
                id: id,
                groupCode: groupCode,
                accessible: true
            )
        }

        XCTAssertEqual(
            StationGroupKey.key(for: station(128, id: 101, groupCode: 6_660_128, lat: 41.385, lon: 2.170)),
            StationGroupKey.key(for: station(324, id: 301, groupCode: 6_660_128, lat: 41.385, lon: 2.170))
        )
        // Offline snapshots drop the group code; the name + rounded position
        // fallback still merges the two lines of the interchange.
        XCTAssertEqual(
            StationGroupKey.key(for: station(128, id: 101, groupCode: nil, lat: 41.385, lon: 2.170)),
            StationGroupKey.key(for: station(324, id: 301, groupCode: nil, lat: 41.38502, lon: 2.17005))
        )
    }
}
