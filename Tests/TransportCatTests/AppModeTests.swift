import XCTest
@testable import TransportCat

/// Tests for `AppMode` raw values (specs S6, S12, S8).
///
/// The raw value is what `@AppStorage("appMode")` persists, so two things
/// must always hold: the four modes decode from their exact strings, and any
/// other string decodes to nil — which is how the screens fall back to
/// `.metro`. Old installations that stored "metro" or "bus" keep working when
/// `fgc` and later `global` join the enum.
final class AppModeTests: XCTestCase {
    // MARK: - Known raw values

    func testTheFourModesDecodeFromTheirPersistedStrings() {
        XCTAssertEqual(AppMode(rawValue: "metro"), .metro)
        XCTAssertEqual(AppMode(rawValue: "bus"), .bus)
        XCTAssertEqual(AppMode(rawValue: "fgc"), .fgc)
        // The global mode (spec S8): raw "global", chip label "Tot".
        XCTAssertEqual(AppMode(rawValue: "global"), .global)
    }

    func testEveryCasePersistsItsLowerCaseName() {
        XCTAssertEqual(AppMode.metro.rawValue, "metro")
        XCTAssertEqual(AppMode.bus.rawValue, "bus")
        XCTAssertEqual(AppMode.fgc.rawValue, "fgc")
        XCTAssertEqual(AppMode.global.rawValue, "global")
    }

    func testRawValuesRoundTrip() {
        for mode in [AppMode.metro, .bus, .fgc, .global] {
            XCTAssertEqual(AppMode(rawValue: mode.rawValue), mode)
        }
    }

    // MARK: - Unknown raw values

    func testUnknownStringDecodesToNil() {
        XCTAssertNil(AppMode(rawValue: ""))
        XCTAssertNil(AppMode(rawValue: "tram"))
        XCTAssertNil(AppMode(rawValue: "fg"))
        XCTAssertNil(AppMode(rawValue: "fgc2"))
        // The chip says "Tot", but "tot" is not the persisted "global".
        XCTAssertNil(AppMode(rawValue: "tot"))
    }

    /// The stored value is the raw string, matched exactly: a mode is not a
    /// fuzzy search, so the capitalized "FGC" is not the persisted "fgc".
    func testMatchingIsCaseSensitive() {
        XCTAssertNil(AppMode(rawValue: "FGC"))
        XCTAssertNil(AppMode(rawValue: "Metro"))
    }
}
