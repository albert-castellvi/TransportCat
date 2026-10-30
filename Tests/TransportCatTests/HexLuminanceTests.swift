import XCTest
@testable import TransportCat

/// Tests for the pill text colour rule (spec S6): `HexLuminance.isLight`.
///
/// Every expectation is the value the sRGB relative luminance formula gives for
/// that colour, with the 0.5 threshold of the spec; the line colours come from
/// `MetroLine.allLines` so a brand colour change fails here instead of shipping
/// unreadable pills.
final class HexLuminanceTests: XCTestCase {
    // MARK: - Line colours

    /// Every TMB line colour gets the text colour with the better WCAG contrast:
    /// the pill text is black exactly when black contrasts more than white.
    func testEveryLineColourGetsTheBetterContrastingText() {
        for line in MetroLine.allLines {
            let hex = line.colorHex
            let value = UInt32(hex, radix: 16) ?? 0
            let rgb = (
                red: Double((value >> 16) & 0xFF) / 255,
                green: Double((value >> 8) & 0xFF) / 255,
                blue: Double(value & 0xFF) / 255
            )
            let luminance = HexLuminance.luminance(of: rgb)
            let contrastWithBlack = (luminance + 0.05) / 0.05
            let contrastWithWhite = 1.05 / (luminance + 0.05)
            XCTAssertEqual(
                HexLuminance.isLight(hex),
                contrastWithBlack > contrastWithWhite,
                "\(line.displayName) (\(hex)) picks the less readable text colour"
            )
        }
    }

    /// Red, purple, blue and the funicular green take white text; the yellow,
    /// orange, light blue and greens take black text (threshold 0.179).
    func testLineColoursPickTheReadableTextColour() {
        XCTAssertFalse(HexLuminance.isLight("CE1126")) // L1
        XCTAssertFalse(HexLuminance.isLight("93248F")) // L2
        XCTAssertTrue(HexLuminance.isLight("1EB53A")) // L3
        XCTAssertTrue(HexLuminance.isLight("F7A30E")) // L4, luminance 0.460
        XCTAssertFalse(HexLuminance.isLight("005A97")) // L5
        XCTAssertTrue(HexLuminance.isLight("FB712B")) // L9N / L9S
        XCTAssertTrue(HexLuminance.isLight("00A6D6")) // L10N / L10S
        XCTAssertTrue(HexLuminance.isLight("89B94C")) // L11, luminance 0.405
        XCTAssertFalse(HexLuminance.isLight("004C38")) // FM
    }

    // MARK: - Reference colours

    func testWhiteIsLight() {
        XCTAssertTrue(HexLuminance.isLight("FFFFFF"))
    }

    func testBlackIsDark() {
        XCTAssertFalse(HexLuminance.isLight("000000"))
    }

    /// Mid grey (0.502 channel) has a luminance of 0.216, just above the 0.179
    /// crossover: black text reads better on it than white.
    func testMidGreyAndLightGreyAreLight() {
        XCTAssertTrue(HexLuminance.isLight("808080"))
        XCTAssertTrue(HexLuminance.isLight("CCCCCC"))
    }

    // MARK: - Accepted input

    func testLeadingHashIsOptional() {
        XCTAssertEqual(HexLuminance.isLight("#FFFFFF"), HexLuminance.isLight("FFFFFF"))
        XCTAssertEqual(HexLuminance.isLight("#CE1126"), HexLuminance.isLight("CE1126"))
    }

    func testLowercaseDigitsAreAccepted() {
        XCTAssertEqual(HexLuminance.isLight("ffffff"), HexLuminance.isLight("FFFFFF"))
        XCTAssertEqual(HexLuminance.isLight("ce1126"), HexLuminance.isLight("CE1126"))
    }

    // MARK: - Rejected input

    func testInvalidInputIsNotLight() {
        XCTAssertFalse(HexLuminance.isLight(""))
        XCTAssertFalse(HexLuminance.isLight("#"))
        XCTAssertFalse(HexLuminance.isLight("FFF"))
        XCTAssertFalse(HexLuminance.isLight("#FFFF"))
        XCTAssertFalse(HexLuminance.isLight("FFFFFFF"))
        XCTAssertFalse(HexLuminance.isLight("GGGGGG"))
        XCTAssertFalse(HexLuminance.isLight("#FFFFF")) // 5 digits after the hash
        XCTAssertFalse(HexLuminance.isLight("FFFFFF#"))
        XCTAssertFalse(HexLuminance.isLight(" FFFFFF"))
    }
}
