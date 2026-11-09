import XCTest
@testable import TransportCat

/// `Color(hex:)` and the parse rule behind it (bug #36): the feed sends
/// `COLOR_LINIA` as an empty default, so a colour string is validated like
/// `HexLuminance` does and anything that is not six hex digits falls back to
/// the neutral grey the rest of the app paints a missing colour with, instead
/// of the opaque black an unchecked `scanHexInt64` produced.
final class ColorFromHexTests: XCTestCase {
    // MARK: - Accepted input

    func testSixDigitHexIsSplitIntoChannels() throws {
        let l1 = try XCTUnwrap(LineColorHex.parse("CE1126"))
        XCTAssertEqual(l1.red * 255, 0xCE, accuracy: 0.001)
        XCTAssertEqual(l1.green * 255, 0x11, accuracy: 0.001)
        XCTAssertEqual(l1.blue * 255, 0x26, accuracy: 0.001)
    }

    func testLeadingHashAndLowercaseDigitsAreAccepted() {
        XCTAssertNotNil(LineColorHex.parse("#CE1126"))
        XCTAssertNotNil(LineColorHex.parse("ce1126"))
        XCTAssertNotNil(LineColorHex.parse("#ce1126"))
    }

    // MARK: - Rejected input

    /// The strings the feed produces when a line has no colour, plus the
    /// length and digit mistakes `HexLuminance` already rejects.
    func testMalformedStringsHaveNoChannels() {
        for hex in ["", "#", "FFF", "#FFFF", "FFFFFFF", "FF003888", "GGGGGG", " FFFFFF", "FFFFFF#"] {
            XCTAssertNil(LineColorHex.parse(hex), "'\(hex)' is not a colour")
        }
    }

    // MARK: - Fallback

    /// An unparsable string paints the neutral grey, not opaque black.
    func testMissingColourFallsBackToTheNeutralGrey() throws {
        let grey = LineColorHex.components(of: "")
        XCTAssertEqual(grey.red * 255, 0x8E, accuracy: 0.001)
        XCTAssertEqual(grey.green * 255, 0x8E, accuracy: 0.001)
        XCTAssertEqual(grey.blue * 255, 0x93, accuracy: 0.001)

        // "FF003888" is a concatenation of two colours: it is not read as one.
        let wrongLength = LineColorHex.components(of: "FF003888")
        XCTAssertEqual(wrongLength.red, grey.red)
        XCTAssertEqual(wrongLength.green, grey.green)
        XCTAssertEqual(wrongLength.blue, grey.blue)
    }

    /// The channels and the hex string of the fallback cannot drift apart.
    func testNeutralHexMatchesTheNeutralChannels() throws {
        XCTAssertEqual(LineColorHex.neutralHex, "8E8E93")
        let parsed = try XCTUnwrap(LineColorHex.parse(LineColorHex.neutralHex))
        XCTAssertEqual(parsed.red, LineColorHex.neutral.red, accuracy: 0.001)
        XCTAssertEqual(parsed.green, LineColorHex.neutral.green, accuracy: 0.001)
        XCTAssertEqual(parsed.blue, LineColorHex.neutral.blue, accuracy: 0.001)
    }
}
