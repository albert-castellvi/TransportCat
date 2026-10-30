import XCTest
@testable import TransportCat

/// The regularity rules of spec S3, with exact numbers: the report is what the
/// Xarxa rows show, so a wrong threshold puts a wrong tag on the screen.
final class RegularityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let headway: TimeInterval = 300

    /// Scheduled arrivals every `headway` seconds, centred around `now`.
    private func timetable(every headway: TimeInterval = 300, count: Int = 10) -> [Date] {
        (0..<count).map { index in
            now.addingTimeInterval(Double(index - count / 2) * headway)
        }
    }

    /// Live arrivals at the given second offsets from `now`.
    private func live(_ offsets: [TimeInterval]) -> [Date] {
        offsets.map { now.addingTimeInterval($0) }
    }

    func testRegularWhenLiveSpacingFollowsTheTimetable() {
        let report = Regularity.assess(live: live([-450, -150, 150, 450]), scheduled: timetable(), now: now)

        XCTAssertEqual(report.status, .regular)
        XCTAssertEqual(report.scheduledHeadway, headway)
        XCTAssertEqual(report.observedHeadway, headway)
        XCTAssertEqual(report.longestGap, headway)
    }

    func testGapWhenALiveGapIsFarAboveTheHeadway() {
        // 600 s between two trains against a 300 s headway: more than 1.8x and
        // more than the 240 s floor.
        let report = Regularity.assess(live: live([-300, 300, 600]), scheduled: timetable(), now: now)

        XCTAssertEqual(report.status, .gap)
        XCTAssertEqual(report.longestGap, 600)
        XCTAssertEqual(report.scheduledHeadway, headway)
        XCTAssertEqual(report.observedHeadway, 450)
    }

    func testGapNeedsTheAbsoluteFloor() {
        // A 200 s gap is 1.8x a 100 s headway but under the 240 s floor: a
        // frequent service is never called a hole.
        let report = Regularity.assess(
            live: live([-100, 100, 300]),
            scheduled: timetable(every: 100),
            now: now
        )

        XCTAssertEqual(report.status, .regular)
        XCTAssertEqual(report.longestGap, 200)
    }

    func testBunchedWhenTwoArrivalsAreOnTopOfEachOther() {
        // A 60 s gap against a 300 s headway is far below 0.35x.
        let report = Regularity.assess(live: live([-300, 0, 60, 360]), scheduled: timetable(), now: now)

        XCTAssertEqual(report.status, .bunched)
        XCTAssertEqual(report.longestGap, 300)
        XCTAssertEqual(report.observedHeadway, 300)
    }

    func testBunchedNeedsALongEnoughHeadway() {
        // The same 0.35x gap on a 100 s headway is meaningless: vehicles are
        // simply close.
        let report = Regularity.assess(
            live: live([-100, 0, 35, 135]),
            scheduled: timetable(every: 100),
            now: now
        )

        XCTAssertEqual(report.status, .regular)
    }

    func testUnknownWithoutTwoLiveArrivals() {
        let report = Regularity.assess(live: live([60]), scheduled: timetable(), now: now)

        XCTAssertEqual(report.status, .unknown)
        XCTAssertEqual(report.scheduledHeadway, headway)
        XCTAssertNil(report.observedHeadway)
        XCTAssertNil(report.longestGap)
    }

    func testUnknownWithoutScheduledHeadway() {
        let report = Regularity.assess(live: live([0, 300]), scheduled: [], now: now)

        XCTAssertEqual(report.status, .unknown)
        XCTAssertNil(report.scheduledHeadway)
        XCTAssertEqual(report.observedHeadway, 300)
        XCTAssertEqual(report.longestGap, 300)
    }

    func testScheduledHeadwayOnlyCountsTheWindowAroundNow() {
        // Spaced 600 s, six arrivals an hour away outnumber the three of the
        // window: if they were counted, the headway would come out as 600.
        let inWindow = live([-300, 0, 300])
        let farAway = live([3_600, 4_200, 4_800, 5_400, 6_000, 6_600])
        let report = Regularity.assess(live: live([0, 300]), scheduled: inWindow + farAway, now: now)

        XCTAssertEqual(report.scheduledHeadway, headway)
    }

    func testMedianHeadwayOfAnUnorderedList() {
        XCTAssertEqual(Regularity.medianHeadway(of: []), nil)
        XCTAssertEqual(Regularity.medianHeadway(of: [now]), nil)
        XCTAssertEqual(
            Regularity.medianHeadway(of: [now, now.addingTimeInterval(100), now.addingTimeInterval(500)]),
            250
        )
    }
}
