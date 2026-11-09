import XCTest
@testable import TransportCat

/// The mode the home-screen quick action builds the line item from (#44).
///
/// `appMode` is written by `AppRouter.open` and by the mode menu only, while
/// browsing lines in the default metro mode persists just
/// `metroSelectedLine`. The effective mode therefore has to fall back to the
/// metro mode the screens default to, instead of leaving the rider without the
/// "last line viewed" item on a fresh install.
@MainActor
final class PersistedModeTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "PersistedModeTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        try super.tearDownWithError()
    }

    /// Fresh install: a line was viewed (so `metroSelectedLine` is stored) but
    /// no mode was ever written.
    func testAFreshInstallIsOnTheMetroMode() {
        defaults.set("3", forKey: AppRouter.metroSelectedLineKey)

        XCTAssertNil(defaults.string(forKey: AppRouter.appModeKey))
        XCTAssertEqual(AppRouter.effectiveMode(defaults: defaults), AppModeCode.metro)
    }

    /// A stored mode is the one the rider last used, and it wins.
    func testAStoredModeWins() {
        defaults.set(AppModeCode.bus, forKey: AppRouter.appModeKey)

        XCTAssertEqual(AppRouter.effectiveMode(defaults: defaults), AppModeCode.bus)
    }
}
