import XCTest
@testable import TransportCat

/// The pure logic behind the Configuració screen (unit `settings`): how a
/// permission state is worded, how the current language is named, and the
/// version row. The screen shows these strings, so they are tested without it.
final class SettingsTests: XCTestCase {
    // MARK: - Permission wording

    func testPermissionWordingCoversTheThreeStates() {
        XCTAssertEqual(SettingsSupport.permissionWording(.granted), "Permesa")
        XCTAssertEqual(SettingsSupport.permissionWording(.denied), "Denegada")
        XCTAssertEqual(SettingsSupport.permissionWording(.notAsked), "Sense demanar")
    }

    func testEveryPermissionHasItsOwnWording() {
        let wordings = SettingsSupport.Permission.allCases.map(SettingsSupport.permissionWording)
        XCTAssertEqual(Set(wordings).count, SettingsSupport.Permission.allCases.count)
        XCTAssertFalse(wordings.contains(where: \.isEmpty))
    }

    // MARK: - Language code and name

    func testLanguageCodeDropsTheRegion() {
        XCTAssertEqual(SettingsSupport.languageCode(from: "ca"), "ca")
        XCTAssertEqual(SettingsSupport.languageCode(from: "ca-ES"), "ca")
        XCTAssertEqual(SettingsSupport.languageCode(from: "ca_ES"), "ca")
        XCTAssertEqual(SettingsSupport.languageCode(from: "en-GB"), "en")
        // The bundle's preferred localizations carry no padding, but a stray
        // one must not become a code with spaces in it.
        XCTAssertEqual(SettingsSupport.languageCode(from: " es "), "es")
    }

    func testLanguageCodeRejectsEmptyIdentifiers() {
        XCTAssertNil(SettingsSupport.languageCode(from: ""))
        XCTAssertNil(SettingsSupport.languageCode(from: "   "))
        XCTAssertNil(SettingsSupport.languageCode(from: "-ES"))
    }

    /// The name is the language's own name in the device's language, with the
    /// first letter capitalised. The English wording is pinned because it is
    /// the one the CLDR data does not reword between OS releases.
    func testLanguageNameIsTheCapitalisedNameInTheDeviceLanguage() {
        let english = Locale(identifier: "en_US")
        XCTAssertEqual(SettingsSupport.languageName(forPreferredLanguage: "ca", locale: english), "Catalan")
        XCTAssertEqual(SettingsSupport.languageName(forPreferredLanguage: "es", locale: english), "Spanish")
        XCTAssertEqual(SettingsSupport.languageName(forPreferredLanguage: "en", locale: english), "English")
        // The region is dropped, so the row reads the language, never "ca-ES".
        XCTAssertEqual(
            SettingsSupport.languageName(forPreferredLanguage: "ca-ES", locale: english),
            SettingsSupport.languageName(forPreferredLanguage: "ca", locale: english)
        )
        // The name follows the device, not the app: on a Catalan phone the
        // same code reads the Catalan word, capitalised.
        let catalan = Locale(identifier: "ca_ES")
        XCTAssertEqual(SettingsSupport.languageName(forPreferredLanguage: "ca", locale: catalan), "Català")
    }

    func testLanguageNameIsNilWithoutALanguage() {
        XCTAssertNil(SettingsSupport.languageName(forPreferredLanguage: nil))
        XCTAssertNil(SettingsSupport.languageName(forPreferredLanguage: ""))
    }

    // MARK: - Version row

    func testVersionRowJoinsShortVersionAndBuild() {
        XCTAssertEqual(SettingsSupport.versionString(shortVersion: "0.1.0", build: "101"), "Versió 0.1.0 (101)")
    }

    func testVersionRowLeavesOutAMissingHalf() {
        XCTAssertEqual(SettingsSupport.versionString(shortVersion: "0.1.0", build: nil), "Versió 0.1.0")
        XCTAssertEqual(SettingsSupport.versionString(shortVersion: "0.1.0", build: "  "), "Versió 0.1.0")
        XCTAssertEqual(SettingsSupport.versionString(shortVersion: nil, build: "101"), "Versió (101)")
        XCTAssertEqual(SettingsSupport.versionString(shortVersion: nil, build: nil), "Versió desconeguda")
    }

    func testVersionRowTrimsTheBundleValues() {
        XCTAssertEqual(SettingsSupport.versionString(shortVersion: " 0.1.0 ", build: " 101\n"), "Versió 0.1.0 (101)")
    }

    // MARK: - Schedule update row

    /// The row dates the cached pack with a medium date. The locale and time
    /// zone are pinned, so the expected text is exact whatever the device is.
    func testScheduleUpdateRowFormatsThePackDate() {
        let text = SettingsSupport.scheduleUpdatedText(
            generatedAt: "2025-04-15T04:30:00Z",
            locale: Locale(identifier: "en_US"),
            timeZone: TimeZone.gmt
        )
        XCTAssertEqual(text, "Horaris de TMB actualitzats el Apr 15, 2025")
    }

    /// Fractional seconds are accepted, in case a future builder adds them.
    func testScheduleUpdateRowAcceptsFractionalSeconds() {
        let text = SettingsSupport.scheduleUpdatedText(
            generatedAt: "2025-04-15T04:30:00.500Z",
            locale: Locale(identifier: "en_US"),
            timeZone: TimeZone.gmt
        )
        XCTAssertEqual(text, "Horaris de TMB actualitzats el Apr 15, 2025")
    }

    /// No valid instant, no row: the screen hides it instead of showing a
    /// placeholder.
    func testScheduleUpdateRowIsNilWithoutAValidInstant() {
        let locale = Locale(identifier: "en_US")
        let timeZone = TimeZone.gmt
        XCTAssertNil(SettingsSupport.scheduleUpdatedText(generatedAt: nil, locale: locale, timeZone: timeZone))
        XCTAssertNil(SettingsSupport.scheduleUpdatedText(generatedAt: "", locale: locale, timeZone: timeZone))
        XCTAssertNil(SettingsSupport.scheduleUpdatedText(generatedAt: "  ", locale: locale, timeZone: timeZone))
        XCTAssertNil(SettingsSupport.scheduleUpdatedText(generatedAt: "not a date", locale: locale, timeZone: timeZone))
    }

    /// The instant parser the row is built on: plain ISO8601 in, fractional
    /// seconds in, garbage and blanks out.
    func testInstantParsing() {
        XCTAssertEqual(
            SettingsSupport.instant(fromISO8601: "2025-04-15T04:30:00Z"),
            Date(timeIntervalSince1970: 1_744_691_400)
        )
        XCTAssertEqual(
            SettingsSupport.instant(fromISO8601: "2025-04-15T04:30:00.500Z"),
            Date(timeIntervalSince1970: 1_744_691_400.5)
        )
        XCTAssertNil(SettingsSupport.instant(fromISO8601: nil))
        XCTAssertNil(SettingsSupport.instant(fromISO8601: "  "))
        XCTAssertNil(SettingsSupport.instant(fromISO8601: "2025-04-15"))
        XCTAssertNil(SettingsSupport.instant(fromISO8601: "2025-04-15T04:30:00"))
    }

    // MARK: - Mode names

    /// The Configuració picker lists every mode by the same word the bottom
    /// accessory's menu uses.
    func testEveryModeHasADisplayNameInMenuOrder() {
        // The menu order is the declaration order: Rodalies sits between FGC
        // and Tot, where the mode menu shows it.
        XCTAssertEqual(AppMode.allCases, [.metro, .bus, .fgc, .rodalies, .global])
        XCTAssertEqual(
            AppMode.allCases.map(\.displayName),
            ["Metro", "Bus", "FGC", "Rodalies", "Tot"]
        )
        // Every mode names an SF Symbol the menu can draw.
        XCTAssertTrue(AppMode.allCases.allSatisfy { !$0.iconName.isEmpty })
    }
}
