import XCTest
@testable import TransportCat

/// Tests for `AppMode` raw values (specs S6, S12).
///
/// The raw value is what `@AppStorage("appMode")` persists, so two things
/// must always hold: the three modes decode from their exact strings, and any
/// other string decodes to nil — which is how the screens fall back to
/// `.metro`. Old installations that stored "metro" or "bus" keep working when
/// `fgc` joins the enum.
final class AppModeTests: XCTestCase {
    // MARK: - Known raw values

    func testTheThreeModesDecodeFromTheirPersistedStrings() {
        XCTAssertEqual(AppMode(rawValue: "metro"), .metro)
        XCTAssertEqual(AppMode(rawValue: "bus"), .bus)
        XCTAssertEqual(AppMode(rawValue: "fgc"), .fgc)
    }

    func testEveryCasePersistsItsLowerCaseName() {
        XCTAssertEqual(AppMode.metro.rawValue, "metro")
        XCTAssertEqual(AppMode.bus.rawValue, "bus")
        XCTAssertEqual(AppMode.fgc.rawValue, "fgc")
    }

    func testRawValuesRoundTrip() {
        for mode in [AppMode.metro, .bus, .fgc] {
            XCTAssertEqual(AppMode(rawValue: mode.rawValue), mode)
        }
    }

    // MARK: - Unknown raw values

    func testUnknownStringDecodesToNil() {
        XCTAssertNil(AppMode(rawValue: ""))
        XCTAssertNil(AppMode(rawValue: "tram"))
        XCTAssertNil(AppMode(rawValue: "fg"))
        XCTAssertNil(AppMode(rawValue: "fgc2"))
    }

    /// The stored value is the raw string, matched exactly: a mode is not a
    /// fuzzy search, so the capitalized "FGC" is not the persisted "fgc".
    func testMatchingIsCaseSensitive() {
        XCTAssertNil(AppMode(rawValue: "FGC"))
        XCTAssertNil(AppMode(rawValue: "Metro"))
    }
}
