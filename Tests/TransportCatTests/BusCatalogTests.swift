import XCTest
@testable import TransportCat

final class BusCatalogTests: XCTestCase {
    // MARK: - Helpers

    private func lines() throws -> [BusLine] {
        try BusParser.lines(from: Fixtures.data("bus-lines-sample"))
    }

    // MARK: - Families (S2)

    func testFamiliesFollowFamilyOrderAndCarryTheirLines() throws {
        let families = BusCatalog.families(of: try lines())
        XCTAssertEqual(families.count, 9)
        // Families follow ORDRE_FAMILIA, which is not alphabetical.
        XCTAssertEqual(
            families.map(\.name),
            [
                "Diagonals", "Horitzontals", "Verticals", "XPRESBus", "Convencionals",
                "Proximitat", "Bus a la Demanda", "BusTuristic", "Llançadores",
            ]
        )
        XCTAssertEqual(families.map(\.order), [10, 11, 12, 13, 14, 14, 15, 16, 17])
        XCTAssertEqual(families.map(\.code), [5, 6, 7, 11, 1, 3, 10, 4, 9])

        let horizontals = try XCTUnwrap(families.first { $0.name == "Horitzontals" })
        XCTAssertEqual(horizontals.lines.map(\.name), ["H12", "H16"])
        // Lines inside a family follow ORDRE_LINIA (212 before 216).
        XCTAssertEqual(horizontals.lines.map(\.order), [212, 216])
        XCTAssertTrue(horizontals.lines.allSatisfy { $0.familyCode == 6 })

        for family in families {
            XCTAssertTrue(family.lines.allSatisfy { $0.familyCode == family.code })
            let orders = family.lines.map(\.order)
            XCTAssertEqual(orders, orders.sorted(), "family \(family.name) is not ordered by ORDRE_LINIA")
        }
    }

    func testFamiliesOfAnEmptyCatalogIsEmpty() {
        XCTAssertTrue(BusCatalog.families(of: []).isEmpty)
    }

    // MARK: - Search (S2)

    func testSearchByLineNameRanksItFirst() throws {
        let lines = try lines()
        let results = BusCatalog.search(lines, query: "H12")
        XCTAssertEqual(results.first?.name, "H12")
        XCTAssertEqual(results.count, 1)
        // The comparison ignores case.
        XCTAssertEqual(BusCatalog.search(lines, query: "h12").map(\.name), ["H12"])
    }

    func testSearchMatchesDestinationsIgnoringDiacritics() throws {
        let lines = try lines()
        for query in ["besòs", "besos", "BESÒS"] {
            let names = BusCatalog.search(lines, query: query).map(\.name)
            XCTAssertEqual(names, ["H12", "H16"], "query \(query) must find both lines toward Besòs")
        }
    }

    func testSearchMatchesOriginAndDescription() throws {
        let lines = try lines()
        // "Gornal" is H12's origin, not its name.
        XCTAssertEqual(BusCatalog.search(lines, query: "gornal").map(\.name), ["H12"])
        // A description-only match: route 135 is named after its description.
        XCTAssertEqual(BusCatalog.search(lines, query: "turístic").map(\.name), ["100"])
    }

    func testSearchPrefersNameMatchesOverOtherMatches() throws {
        let lines = try lines()
        // "v" prefixes V15 and V27 by name and also appears in other lines'
        // descriptions ("Verneda", "Vall d'Hebron"...).
        let results = BusCatalog.search(lines, query: "v").map(\.name)
        XCTAssertEqual(Array(results.prefix(2)), ["V15", "V27"])
        XCTAssertEqual(results, ["V15", "V27", "H12", "X3", "7", "135", "100"])
    }

    func testEmptyQueryReturnsTheCatalogUnchanged() throws {
        let lines = try lines()
        XCTAssertEqual(BusCatalog.search(lines, query: "").map(\.code), lines.map(\.code))
        XCTAssertEqual(BusCatalog.search(lines, query: "   ").map(\.code), lines.map(\.code))
    }

    func testSearchWithoutMatchesIsEmpty() throws {
        XCTAssertTrue(BusCatalog.search(try lines(), query: "aeroport").isEmpty)
    }
}
