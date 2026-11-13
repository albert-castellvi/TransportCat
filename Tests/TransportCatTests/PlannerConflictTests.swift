import XCTest
@testable import TransportCat

/// Picker assignment and conflict resolution for applyPlannerPick
/// (GitHub issue #96 remaining item).
final class PlannerConflictTests: XCTestCase {
    private func geo(_ lat: Double, _ lon: Double) -> GeoPoint {
        GeoPoint(latitude: lat, longitude: lon)
    }

    private func currentEndpoint() -> PlannerEndpoint {
        PlannerEndpoint(label: "La meva ubicació", position: geo(41.38, 2.16), isCurrentLocation: true)
    }

    private func placeEndpoint() -> PlannerEndpoint {
        PlannerEndpoint(label: "Catalunya", position: geo(41.3873, 2.1686))
    }

    // MARK: - Picking a manual place

    func testPickingManualPlaceSetsOriginAndKeepsDestination() {
        let destination = placeEndpoint()
        let (origin, resultDest) = applyPlannerPick(
            placeEndpoint(),
            to: .origin,
            origin: nil,
            destination: destination
        )
        XCTAssertEqual(origin, placeEndpoint())
        XCTAssertEqual(resultDest, destination)
    }

    func testPickingManualPlaceSetsDestinationAndKeepsOrigin() {
        let origin = placeEndpoint()
        let (resultOrigin, destination) = applyPlannerPick(
            placeEndpoint(),
            to: .destination,
            origin: origin,
            destination: nil
        )
        XCTAssertEqual(resultOrigin, origin)
        XCTAssertEqual(destination, placeEndpoint())
    }

    // MARK: - Picking current location with conflict

    func testPickingCurrentDestinationClearsCurrentOrigin() {
        let origin = currentEndpoint()
        let (resultOrigin, destination) = applyPlannerPick(
            currentEndpoint(),
            to: .destination,
            origin: origin,
            destination: nil
        )
        XCTAssertNil(resultOrigin)
        XCTAssertEqual(destination, currentEndpoint())
    }

    func testPickingCurrentOriginClearsCurrentDestination() {
        let destination = currentEndpoint()
        let (origin, resultDest) = applyPlannerPick(
            currentEndpoint(),
            to: .origin,
            origin: nil,
            destination: destination
        )
        XCTAssertEqual(origin, currentEndpoint())
        XCTAssertNil(resultDest)
    }

    // MARK: - No conflict: current location with manual other

    func testPickingCurrentLocationKeepsManualOther() {
        let origin = currentEndpoint()
        let (resultOrigin, destination) = applyPlannerPick(
            placeEndpoint(),
            to: .destination,
            origin: origin,
            destination: nil
        )
        XCTAssertEqual(resultOrigin, origin)
        XCTAssertEqual(destination, placeEndpoint())
    }

    func testPickingManualDestinationKeepsCurrentOrigin() {
        let destination = currentEndpoint()
        let (origin, resultDest) = applyPlannerPick(
            placeEndpoint(),
            to: .origin,
            origin: nil,
            destination: destination
        )
        XCTAssertEqual(origin, placeEndpoint())
        XCTAssertEqual(resultDest, destination)
    }

    // MARK: - Both nil

    func testPickingCurrentLocationWithBothNilSetsOnlyTarget() {
        let current = currentEndpoint()
        let (origin, destination) = applyPlannerPick(
            current,
            to: .origin,
            origin: nil,
            destination: nil
        )
        XCTAssertEqual(origin, current)
        XCTAssertNil(destination)
    }

    func testPickingManualPlaceWithBothNilSetsOnlyTarget() {
        let place = placeEndpoint()
        let (origin, destination) = applyPlannerPick(
            place,
            to: .destination,
            origin: nil,
            destination: nil
        )
        XCTAssertNil(origin)
        XCTAssertEqual(destination, place)
    }
}