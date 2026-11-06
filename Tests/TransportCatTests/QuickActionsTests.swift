import XCTest

@testable import TransportCat

/// The pure quick-action rules (spec S14): the item type strings, the route
/// mapping, and the title of the "last line viewed" item.
final class QuickActionsTests: XCTestCase {
    // MARK: - Route mapping

    func testEveryTypeStringMapsToItsRoute() {
        XCTAssertEqual(QuickActions.route(forType: QuickActionType.nearby), .nearby)
        XCTAssertEqual(QuickActions.route(forType: QuickActionType.lastLine), .lastLine)
        XCTAssertEqual(QuickActions.route(forType: QuickActionType.alerts), .alerts)
        XCTAssertEqual(QuickActions.route(forType: QuickActionType.searchStop), .searchStop)
    }

    func testEveryDeclaredTypeHasARoute() {
        for type in QuickActionType.all {
            XCTAssertNotNil(QuickActions.route(forType: type), "No route for \(type)")
        }
    }

    func testUnknownTypeStringMapsToNil() {
        XCTAssertNil(QuickActions.route(forType: "cat.transport.app.qa.unknown"))
        XCTAssertNil(QuickActions.route(forType: ""))
        // A type string that only shares a prefix with a known one is unknown.
        XCTAssertNil(QuickActions.route(forType: QuickActionType.nearby + ".extra"))
    }

    // MARK: - Last-line title

    func testLastLineTitleWithDetail() {
        XCTAssertEqual(
            QuickActions.lastLineTitle(displayCode: "L2", detail: "Paral·lel – Badalona"),
            "L2 · Paral·lel – Badalona"
        )
    }

    func testLastLineTitleWithoutDetailIsJustTheCode() {
        XCTAssertEqual(QuickActions.lastLineTitle(displayCode: "S1", detail: nil), "S1")
        // An empty detail counts as no detail.
        XCTAssertEqual(QuickActions.lastLineTitle(displayCode: "H12", detail: ""), "H12")
    }

    // MARK: - Metro display code

    func testKnownMetroLineGivesItsDisplayName() {
        // Stored key is the TMB CODI_LINIA ("2"); the badge shows "L2".
        XCTAssertEqual(QuickActions.metroDisplayCode(lineCode: "2"), "L2")
        XCTAssertEqual(QuickActions.metroDisplayCode(lineCode: "94"), "L9N")
    }

    func testUnknownMetroLineFallsBackToTheStoredCode() {
        XCTAssertEqual(QuickActions.metroDisplayCode(lineCode: "ZZ"), "ZZ")
        XCTAssertEqual(QuickActions.metroDisplayCode(lineCode: ""), "")
    }

    // MARK: - Last-line destination

    func testLineModesGiveTheirDestination() {
        XCTAssertEqual(
            QuickActions.lastLineDestination(mode: AppModeCode.metro, lineCode: "2"),
            Destination.line(operator: AppModeCode.metro, code: "2")
        )
        XCTAssertEqual(
            QuickActions.lastLineDestination(mode: AppModeCode.bus, lineCode: "212"),
            Destination.line(operator: AppModeCode.bus, code: "212")
        )
        XCTAssertEqual(
            QuickActions.lastLineDestination(mode: AppModeCode.fgc, lineCode: "S1"),
            Destination.line(operator: AppModeCode.fgc, code: "S1")
        )
    }

    func testNonLineModeGivesNoDestination() {
        XCTAssertNil(QuickActions.lastLineDestination(mode: "global", lineCode: "1"))
        XCTAssertNil(QuickActions.lastLineDestination(mode: "", lineCode: "1"))
    }
}
