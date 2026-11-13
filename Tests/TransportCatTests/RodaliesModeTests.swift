import XCTest
@testable import TransportCat

/// The Rodalies mode's place in the router and in the line selection: which
/// mode a Rodalies place routes to, which line key the router writes, and the
/// resolution rule the chip, the map and the Parades timeline share.
@MainActor
final class RodaliesModeTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "RodaliesModeTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        try await super.tearDown()
    }

    private func place() -> Place {
        Place(
            kind: .rodaliesStation,
            code: "71801",
            name: "Barcelona-Sants",
            position: GeoPoint(latitude: 41.379, longitude: 2.14),
            lineCodes: ["R1"],
            accessible: true
        )
    }

    // MARK: - Routing

    /// A Rodalies place goes to the Rodalies mode, not to the FGC one it used to
    /// fall back to.
    func testARodaliesPlaceRoutesToTheRodaliesMode() {
        XCTAssertEqual(Destination.place(place()).operator, AppModeCode.rodalies)
        XCTAssertEqual(AppModeCode.rodalies, "rodalies")
    }

    /// Opening a Rodalies line persists both the mode and the line under the key
    /// every Rodalies surface reads.
    func testOpeningARodaliesLinePersistsModeAndLine() {
        let router = AppRouter(defaults: defaults)
        router.open(.line(operator: AppModeCode.rodalies, code: "R2N"))

        XCTAssertEqual(defaults.string(forKey: AppRouter.appModeKey), AppModeCode.rodalies)
        XCTAssertEqual(defaults.string(forKey: AppRouter.rodaliesSelectedLineKey), "R2N")
        XCTAssertEqual(router.selectedTab, .map)
        XCTAssertEqual(router.pendingFocus, .line(operator: AppModeCode.rodalies, code: "R2N"))
        // The FGC key is not touched: the two modes keep their own line.
        XCTAssertNil(defaults.string(forKey: AppRouter.fgcSelectedLineKey))
    }

    // MARK: - Line selection

    func testTheBundledTopologyCarriesTheNucleus() throws {
        let topology = try XCTUnwrap(RodaliesTopology.bundled)
        XCTAssertEqual(topology.lines.count, 19)
        XCTAssertTrue(topology.lines.allSatisfy { line in
            !line.colorHex.isEmpty && !line.textColorHex.isEmpty && !line.name.isEmpty
        })
        // The default the screens open with is one of them.
        XCTAssertTrue(
            topology.lines.contains {
                $0.code == RodaliesLineSelection.defaultLineCode
            }
        )
    }

    func testTheStoredLineIsKeptOnlyWhenTheTopologyKnowsIt() {
        let lines = [
            RodaliesLine(code: "R1", name: "Molins de Rei - Maçanet", colorHex: "1E90FF", textColorHex: "FFFFFF"),
            RodaliesLine(code: "R2N", name: "Barcelona - Granollers", colorHex: "00843D", textColorHex: "FFFFFF"),
        ]
        XCTAssertEqual(RodaliesLineSelection.resolve(selected: "R2N", from: lines), "R2N")
        // An unknown code falls back to the first line...
        XCTAssertEqual(RodaliesLineSelection.resolve(selected: "R99", from: lines), "R1")
        // ...and an empty topology keeps the stored code, so the chip never
        // shows a line the rider did not pick.
        XCTAssertEqual(RodaliesLineSelection.resolve(selected: "R2N", from: []), "R2N")
    }

    /// The key is the one the chip, the map and the Parades screen read.
    func testTheSelectionKeyIsStable() {
        XCTAssertEqual(RodaliesLineSelection.storageKey, "rodaliesSelectedLine")
        XCTAssertEqual(AppRouter.rodaliesSelectedLineKey, RodaliesLineSelection.storageKey)
    }
}
