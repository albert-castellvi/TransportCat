import XCTest
@testable import TransportCat

/// Tests for the shared bus direction selection (spec S4): the stored
/// `ID_SENTIT` resolved against a line's directions, and the swap rule the
/// bottom accessory uses.
///
/// The API is fixed by the redesign spec: `resolve(stored:available:)` and
/// `swapped(current:available:)` on `BusDirectionSelection`, with the storage
/// key "busDirectionID".
final class BusDirectionSelectionTests: XCTestCase {
    // MARK: - Storage key

    func testStorageKeyIsTheAgreedString() {
        XCTAssertEqual(BusDirectionSelection.storageKey, "busDirectionID")
    }

    // MARK: - resolve(stored:available:)

    func testStoredDirectionWhenItIsAvailable() {
        XCTAssertEqual(BusDirectionSelection.resolve(stored: 2, available: [1, 2]), 2)
        XCTAssertEqual(BusDirectionSelection.resolve(stored: 1, available: [1]), 1)
        // Order of the available list does not matter.
        XCTAssertEqual(BusDirectionSelection.resolve(stored: 1, available: [2, 1]), 1)
    }

    func testUnknownStoredFallsBackToTheFirstAvailable() {
        XCTAssertEqual(BusDirectionSelection.resolve(stored: 9, available: [2, 1]), 2)
        XCTAssertEqual(BusDirectionSelection.resolve(stored: 7, available: [1, 2]), 1)
    }

    func testEmptyAvailableResolvesToNil() {
        XCTAssertNil(BusDirectionSelection.resolve(stored: 1, available: []))
    }

    // MARK: - swapped(current:available:)

    func testTwoDirectionsSwapToEachOther() {
        XCTAssertEqual(BusDirectionSelection.swapped(current: 1, available: [1, 2]), 2)
        XCTAssertEqual(BusDirectionSelection.swapped(current: 2, available: [1, 2]), 1)
        // The next one in `available`, wrapping: a swapped-back swap returns.
        XCTAssertEqual(BusDirectionSelection.swapped(current: 2, available: [1, 2, 3]), 3)
        XCTAssertEqual(BusDirectionSelection.swapped(current: 3, available: [1, 2, 3]), 1)
    }

    func testCurrentMissingFromAvailableSwapsToTheFirstOther() {
        XCTAssertEqual(BusDirectionSelection.swapped(current: 9, available: [2, 1]), 2)
    }

    func testSingleDirectionSwapsToItself() {
        XCTAssertEqual(BusDirectionSelection.swapped(current: 1, available: [1]), 1)
        XCTAssertEqual(BusDirectionSelection.swapped(current: 2, available: [1]), 1)
    }

    func testEmptyAvailableSwapsToItself() {
        XCTAssertEqual(BusDirectionSelection.swapped(current: 1, available: []), 1)
    }
}
