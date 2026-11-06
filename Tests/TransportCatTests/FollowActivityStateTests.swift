import XCTest

@testable import TransportCat

/// The pure plan → `ContentState` mapping the follow Live Activity draws
/// (S8): names always travel, dates only when the feed has an ETA (D1: FGC
/// has none), and the progress passes through unchanged.
final class FollowActivityStateTests: XCTestCase {
    /// Fixed instant every expected date is computed from.
    private let now = Date(timeIntervalSince1970: 1_770_000_000)

    private func followVehicle(mode: FollowMode) -> FollowVehicle {
        FollowVehicle(
            mode: mode,
            vehicleID: "v1",
            lineDisplayName: "L2",
            lineColorHex: "0A7CFF",
            terminusName: "Badalona",
            isEstimated: mode != .fgc
        )
    }

    private func followStop(name: String, etaSeconds: Int?) -> FollowStop {
        FollowStop(code: name, name: name, etaSeconds: etaSeconds, interchanges: [], facilityNote: nil)
    }

    private func followPlan(
        mode: FollowMode,
        next: FollowStop?,
        alight: FollowStop?,
        progressToAlight: Double?
    ) -> FollowPlan {
        FollowPlan(
            vehicle: followVehicle(mode: mode),
            next: next,
            upcoming: [],
            strip: [],
            mapLabels: [],
            alight: alight,
            alarmStop: nil,
            progressToAlight: progressToAlight
        )
    }

    func testMetroMapsNextNameAlightAndProgress() {
        let plan = followPlan(
            mode: .metro,
            next: followStop(name: "Sant Martí", etaSeconds: 180),
            alight: followStop(name: "La Pau", etaSeconds: 480),
            progressToAlight: 0.25
        )

        let state = FollowActivityController.contentState(for: plan, now: now)

        XCTAssertEqual(state.nextStopName, "Sant Martí")
        XCTAssertEqual(state.nextArrival, now.addingTimeInterval(180))
        XCTAssertEqual(state.alightStopName, "La Pau")
        XCTAssertEqual(state.alightArrival, now.addingTimeInterval(480))
        XCTAssertEqual(state.progress, 0.25)
        XCTAssertFalse(state.isStale)
    }

    func testFGCMapsNamesWithoutDates() {
        let plan = followPlan(
            mode: .fgc,
            next: followStop(name: "Gràcia", etaSeconds: nil),
            alight: followStop(name: "Sarrià", etaSeconds: nil),
            progressToAlight: 0.4
        )

        let state = FollowActivityController.contentState(for: plan, now: now)

        XCTAssertEqual(state.nextStopName, "Gràcia")
        XCTAssertNil(state.nextArrival)
        XCTAssertEqual(state.alightStopName, "Sarrià")
        XCTAssertNil(state.alightArrival)
        XCTAssertEqual(state.progress, 0.4)
    }

    func testWithoutAlightOmitsAlightFieldsAndProgress() {
        let plan = followPlan(
            mode: .bus,
            next: followStop(name: "Plaça Catalunya", etaSeconds: 90),
            alight: nil,
            progressToAlight: nil
        )

        let state = FollowActivityController.contentState(for: plan, now: now)

        XCTAssertEqual(state.nextStopName, "Plaça Catalunya")
        XCTAssertEqual(state.nextArrival, now.addingTimeInterval(90))
        XCTAssertNil(state.alightStopName)
        XCTAssertNil(state.alightArrival)
        XCTAssertNil(state.progress)
    }

    func testWithoutNextStopKeepsAlightOnly() {
        let plan = followPlan(
            mode: .metro,
            next: nil,
            alight: followStop(name: "La Pau", etaSeconds: 60),
            progressToAlight: 0.9
        )

        let state = FollowActivityController.contentState(for: plan, now: now)

        XCTAssertNil(state.nextStopName)
        XCTAssertNil(state.nextArrival)
        XCTAssertEqual(state.alightStopName, "La Pau")
        XCTAssertEqual(state.alightArrival, now.addingTimeInterval(60))
        XCTAssertEqual(state.progress, 0.9)
    }
}
