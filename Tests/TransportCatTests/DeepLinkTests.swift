import XCTest
@testable import TransportCat

/// `DeepLink`: the widget's and the Live Activity's way into one place.
final class DeepLinkTests: XCTestCase {
    private func place(_ kind: PlaceKind, _ code: String, _ name: String) -> Place {
        Place(
            kind: kind,
            code: code,
            name: name,
            position: GeoPoint(latitude: 41.385, longitude: 2.170),
            lineCodes: [],
            accessible: nil
        )
    }

    private func target(_ url: URL) -> DeepLink.Target? {
        DeepLink.target(from: url)
    }

    // MARK: - Round trip

    func testEveryKindOfPlaceRoundTripsThroughItsLink() throws {
        let cases: [(PlaceKind, String, String)] = [
            (.metroStation, "128", "Catalunya"),
            (.busStop, "1468", "Gran Via - Marina"),
            (.fgcStation, "CT", "Creu Alta"),
        ]

        for (kind, code, name) in cases {
            let url = try XCTUnwrap(DeepLink.url(for: place(kind, code, name)))
            XCTAssertEqual(url.scheme, "transportcat")
            XCTAssertEqual(url.host, "place")
            XCTAssertEqual(
                target(url),
                DeepLink.Target(kind: kind, code: code, name: name),
                "round trip failed for \(kind.rawValue)"
            )
        }
    }

    func testTheLinkCarriesTheNameSoAColdLaunchCanOpenThePlace() throws {
        let url = try XCTUnwrap(
            DeepLink.url(kind: .metroStation, code: "128", name: "Sant Adrià de Besòs / Nord")
        )

        XCTAssertFalse(url.absoluteString.contains(" "), "the name must be percent-encoded")
        XCTAssertEqual(target(url)?.name, "Sant Adrià de Besòs / Nord")
    }

    func testAPlaceWithoutANameStillMakesAUsableLink() throws {
        let url = try XCTUnwrap(DeepLink.url(kind: .busStop, code: "774", name: nil))

        XCTAssertEqual(target(url), DeepLink.Target(kind: .busStop, code: "774", name: nil))
        XCTAssertEqual(target(url)?.name, nil)
    }

    func testAnEmptyNameIsNotCarriedAsAnEmptyQueryItem() throws {
        let url = try XCTUnwrap(DeepLink.url(kind: .metroStation, code: "128", name: ""))

        XCTAssertNil(target(url)?.name)
    }

    // MARK: - Refusals

    func testAnEmptyCodeMakesNoLink() {
        XCTAssertNil(DeepLink.url(kind: .metroStation, code: "", name: "Catalunya"))
    }

    func testAForeignSchemeIsNotOurs() {
        let url = URL(string: "https://place/metroStation/128")!

        XCTAssertNil(target(url))
    }

    func testAnotherHostIsNotAPlace() {
        let url = URL(string: "transportcat://line/metroStation/128")!

        XCTAssertNil(target(url))
    }

    func testAnUnknownKindIsRefused() {
        let url = URL(string: "transportcat://place/airport/128")!

        XCTAssertNil(target(url))
    }

    func testAMissingCodeIsRefused() {
        XCTAssertNil(target(URL(string: "transportcat://place/metroStation")!))
        XCTAssertNil(target(URL(string: "transportcat://place/metroStation/")!))
    }

    func testAnExtraPathComponentIsRefused() {
        XCTAssertNil(target(URL(string: "transportcat://place/metroStation/128/extra")!))
    }

    func testTheSchemeAndHostAreMatchedCaseInsensitively() {
        let url = URL(string: "TransportCat://Place/metroStation/128")!

        XCTAssertEqual(target(url)?.code, "128")
    }
}
