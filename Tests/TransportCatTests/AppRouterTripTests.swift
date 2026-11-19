import XCTest
@testable import TransportCat

/// `AppRouter.showActiveTripOnMap()` (spec S4): starting a trip from the
/// planner or Explora lands on the map tab, and the persisted mode is the
/// global one — the same `appMode` key the mode menu writes — because a trip
/// pins its lines on the global map.
@MainActor
final class AppRouterTripTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var router: AppRouter!

    // The async variants run on the class's main actor; the synchronous
    // setUpWithError/tearDownWithError are nonisolated and cannot touch the
    // main-actor stored properties.
    override func setUp() async throws {
        try await super.setUp()
        suiteName = "AppRouterTripTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        router = AppRouter(defaults: defaults)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        router = nil
        try await super.tearDown()
    }

    func testShowActiveTripOnMapPersistsGlobalModeAndSelectsMapTab() {
        // Whatever mode the rider was on — and whatever tab they were in —
        // following a trip always lands on the global map.
        defaults.set(AppModeCode.bus, forKey: AppRouter.appModeKey)
        router.selectedTab = .explore

        router.showActiveTripOnMap()

        XCTAssertEqual(defaults.string(forKey: AppRouter.appModeKey), AppMode.global.rawValue)
        XCTAssertEqual(router.selectedTab, .map)
    }

    func testShowActiveTripOnMapOverwritesAnotherStoredMode() {
        defaults.set(AppModeCode.rodalies, forKey: AppRouter.appModeKey)

        router.showActiveTripOnMap()

        XCTAssertEqual(AppRouter.effectiveMode(defaults: defaults), AppMode.global.rawValue)
    }
}
