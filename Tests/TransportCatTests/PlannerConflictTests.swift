import XCTest
@testable import TransportCat

/// Current-location conflict resolution (#96 remaining item).
/// `resolveCurrentLocationConflict` is a pure function, Foundation-only.
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

    // MARK: - No conflict: the other side is nil

    func testCurrentLocationKeptWhenOtherIsNil() {
        let current = currentEndpoint()
        let (origin, destination) = resolveCurrentLocationConflict(
            existingOrigin: nil,
            existingDestination: nil,
            proposedEndpoint: current,
            target: .origin
        )
        XCTAssertEqual(origin, current)
        XCTAssertNil(destination)
    }

    func testCurrentLocationKeptWhenOtherIsManualPlace() {
        let current = currentEndpoint()
        let place = placeEndpoint()
        let (origin, destination) = resolveCurrentLocationConflict(
            existingOrigin: nil,
            existingDestination: place,
            proposedEndpoint: current,
            target: .origin
        )
        XCTAssertEqual(origin, current)
        XCTAssertEqual(destination, place)
    }

    // MARK: - No conflict: manual place proposed

    func testManualPlaceNeverCausesConflict() {
        let current = currentEndpoint()
        let (origin, destination) = resolveCurrentLocationConflict(
            existingOrigin: current,
            existingDestination: current,
            proposedEndpoint: placeEndpoint(),
            target: .origin
        )
        // Neither endpoint is changed: a manual place never clears the other side.
        XCTAssertEqual(origin, current)
        XCTAssertEqual(destination, current)
    }

    // MARK: - Conflict: both would be current location

    func testSettingOriginClearsDestinationWhenDestinationIsCurrent() {
        let current = currentEndpoint()
        let (origin, destination) = resolveCurrentLocationConflict(
            existingOrigin: nil,
            existingDestination: current,
            proposedEndpoint: current,
            target: .origin
        )
        // Origin is the explicit choice → keep it; clear destination.
        XCTAssertEqual(origin, current)
        XCTAssertNil(destination)
    }

    func testSettingDestinationClearsOriginWhenOriginIsCurrent() {
        let current = currentEndpoint()
        let (origin, destination) = resolveCurrentLocationConflict(
            existingOrigin: current,
            existingDestination: nil,
            proposedEndpoint: current,
            target: .destination
        )
        // Destination is the explicit choice → keep it; clear origin.
        XCTAssertNil(origin)
        XCTAssertEqual(destination, current)
    }

    // MARK: - Edge cases

    func testNoConflictWhenBothManualPlaces() {
        let placeA = placeEndpoint()
        let placeB = PlannerEndpoint(label: "Glòries", position: geo(41.3954, 2.1790))
        let (origin, destination) = resolveCurrentLocationConflict(
            existingOrigin: placeA,
            existingDestination: placeB,
            proposedEndpoint: placeB,
            target: .destination
        )
        XCTAssertEqual(origin, placeA)
        XCTAssertEqual(destination, placeB)
    }

    func testOriginClearedAfterManualPlaceThenCurrentLocationConflict() {
        let current = currentEndpoint()
        let manual = placeEndpoint()

        // First, set origin to manual place.
        let (o1, _) = resolveCurrentLocationConflict(
            existingOrigin: nil,
            existingDestination: nil,
            proposedEndpoint: manual,
            target: .origin
        )
        XCTAssertEqual(o1, manual)

        // Then, pick current location as destination while origin is still manual.
        let (o2, d2) = resolveCurrentLocationConflict(
            existingOrigin: o1,
            existingDestination: nil,
            proposedEndpoint: current,
            target: .destination
        )
        XCTAssertEqual(o2, manual)
        XCTAssertEqual(d2, current)
    }
}