import XCTest
@testable import TransportCat

/// Pure rules of "A prop teu" (spec S10): walking-time conversion, sort order,
/// cap, empty input, and the line-row grouping the stop cards show.
final class NearbyStopsTests: XCTestCase {
    // MARK: - Helpers

    private func place(
        id: String,
        name: String,
        lat: Double,
        lon: Double,
        kind: PlaceKind = .metroStation,
        lines: [String] = []
    ) -> Place {
        Place(
            kind: kind,
            code: id,
            name: name,
            position: GeoPoint(latitude: lat, longitude: lon),
            lineCodes: lines,
            accessible: nil
        )
    }

    private func entry(
        place: Place,
        distanceMeters: Double,
        rows: [NearbyLineRow] = []
    ) -> NearbyStopEntry {
        NearbyStopEntry(
            place: place,
            distanceMeters: distanceMeters,
            walkingMinutes: NearbyStops.walkingMinutes(meters: distanceMeters),
            rows: rows
        )
    }

    // MARK: - walking minutes (stated speed: 80 m/min)

    func testWalkingMinutesOfKnownDistances() {
        // 80 m/min: 250 m rounds to 3, 400 m to 5.
        XCTAssertEqual(NearbyStops.walkingMinutes(meters: 250), 3)
        XCTAssertEqual(NearbyStops.walkingMinutes(meters: 400), 5)
    }

    func testWalkingMinutesFloorOfOneForNonZeroDistance() {
        XCTAssertEqual(NearbyStops.walkingMinutes(meters: 10), 1)
        XCTAssertEqual(NearbyStops.walkingMinutes(meters: 0), 0)
    }

    func testWalkingSpeedConstantIsTheDocumentedOne() {
        XCTAssertEqual(NearbyStops.walkingSpeedMetersPerMinute, 80)
    }

    // MARK: - entries

    func testEntriesWithoutUserLocationAreEmpty() {
        let places = [place(id: "1", name: "A", lat: 41.38, lon: 2.17)]
        XCTAssertTrue(NearbyStops.entries(userLocation: nil, places: places).isEmpty)
    }

    func testEntriesAreEmptyWithNoPlaces() {
        XCTAssertTrue(
            NearbyStops.entries(
                userLocation: GeoPoint(latitude: 41.38, longitude: 2.17),
                places: []
            ).isEmpty
        )
    }

    func testEntriesDropPlacesBeyondTheRadius() {
        // ~1.5 km south: outside the 1 km radius.
        let far = place(id: "2", name: "Lluny", lat: 41.3665, lon: 2.17)
        let near = place(id: "1", name: "A prop", lat: 41.3805, lon: 2.17)
        let entries = NearbyStops.entries(
            userLocation: GeoPoint(latitude: 41.38, longitude: 2.17),
            places: [far, near]
        )
        // `Place.id` is "<kind>:<code>"; the code is what the fixture names.
        XCTAssertEqual(entries.map(\.place.code), ["1"])
    }

    // MARK: - sort order (walking time, then name) and cap

    func testSortedByWalkingTimeThenName() {
        let a = place(id: "a", name: "Casa de l'Aigua", lat: 41.38, lon: 2.17)
        let b = place(id: "b", name: "Almeda", lat: 41.38, lon: 2.17)
        let c = place(id: "c", name: "Badal", lat: 41.38, lon: 2.17)
        // a and b share a walking time (300 m = 4 min) and sort by name; c is
        // a shorter walk (20 m = 1 min) and comes first.
        let unsorted = [
            entry(place: a, distanceMeters: 300),
            entry(place: b, distanceMeters: 300),
            entry(place: c, distanceMeters: 20),
        ]
        let sorted = NearbyStops.sorted(unsorted)
        XCTAssertEqual(sorted.map(\.place.code), ["c", "b", "a"])
    }

    func testSortedCapsAtMaxStops() {
        let many = (0..<15).map { index in
            entry(
                place: place(id: "p\(index)", name: String(format: "P%02d", index), lat: 41.38, lon: 2.17),
                distanceMeters: Double(50 * index + 10)
            )
        }
        XCTAssertEqual(NearbyStops.sorted(many).count, NearbyStops.maxStops)
    }

    func testSortedKeepsCloserStopWhenInputExceedsTheCap() {
        let closest = entry(
            place: place(id: "near", name: "Aqüeducte", lat: 41.38, lon: 2.17),
            distanceMeters: 5
        )
        let far = (0..<12).map { index in
            entry(
                place: place(id: "far\(index)", name: "Lluny\(index)", lat: 41.38, lon: 2.17),
                distanceMeters: 500 + Double(index)
            )
        }
        let sorted = NearbyStops.sorted(far + [closest])
        XCTAssertEqual(sorted.count, NearbyStops.maxStops)
        XCTAssertEqual(sorted.first?.place.code, "near")
    }

    func testSortedEmptyInputStaysEmpty() {
        XCTAssertTrue(NearbyStops.sorted([]).isEmpty)
    }

    // MARK: - line rows

    private func arrival(
        lineCode: String,
        seconds: Int?,
        destination: String = "Fondo"
    ) -> Arrival {
        Arrival(
            stationCode: 1,
            lineCode: lineCode,
            destination: destination,
            seconds: seconds,
            rawText: "",
            via: 1
        )
    }

    private func busArrival(
        lineName: String,
        seconds: Int,
        destination: String = "Badal"
    ) -> BusArrival {
        BusArrival(
            stopCode: 1,
            lineCode: 212,
            lineName: lineName,
            directionID: 1,
            trajectCode: "T1",
            destination: destination,
            seconds: seconds,
            busID: 1,
            rampStatus: nil
        )
    }

    private func h12() -> BusLine {
        BusLine(
            code: 212,
            name: "H12",
            description: "desc",
            origin: "orig",
            destination: "dest",
            colorHex: "003888",
            textColorHex: "FFFFFF",
            familyCode: 1,
            familyName: "Horitzontals",
            familyOrder: 1,
            order: 1
        )
    }

    func testLineRowsGroupMetroByLineWithTwoDirections() {
        let rows = NearbyStops.lineRows(
            metroArrivals: [
                arrival(lineCode: "2", seconds: 240, destination: "Paral·lel"),
                arrival(lineCode: "2", seconds: 60, destination: "Badalona"),
                arrival(lineCode: "2", seconds: 400, destination: "Tercer"),
                arrival(lineCode: "1", seconds: 90, destination: "Fondo"),
            ],
            busArrivals: [],
            fgcArrivals: [],
            busLines: []
        )
        XCTAssertEqual(rows.count, 2)
        let l2 = rows.first { $0.lineLabel == "L2" }
        XCTAssertEqual(l2?.colorHex, "93248F")
        XCTAssertEqual(l2?.firstDestination, "Badalona")
        XCTAssertEqual(l2?.firstTime, "ara")
        XCTAssertEqual(l2?.secondDestination, "Paral·lel")
        XCTAssertEqual(l2?.secondTime, "4 min")
    }

    func testLineRowsGroupBusByLineNameWithCatalogColour() {
        let rows = NearbyStops.lineRows(
            metroArrivals: [],
            busArrivals: [
                busArrival(lineName: "H12", seconds: 30),
                busArrival(lineName: "H12", seconds: 300),
            ],
            fgcArrivals: [],
            busLines: [h12()]
        )
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].lineLabel, "H12")
        XCTAssertEqual(rows[0].colorHex, "003888")
        XCTAssertEqual(rows[0].textColorHex, "FFFFFF")
        XCTAssertEqual(rows[0].firstTime, "ara")
        // 300 s is five whole minutes (`Arrival.countdownText` truncates).
        XCTAssertEqual(rows[0].secondTime, "5 min")
    }

    func testLineRowsCarryFGCStatusWithoutMinutes() {
        let fgc = FavoriteArrival(
            id: "t1",
            lineLabel: "S1",
            colorHex: "84BD00",
            textColorHex: "10220A",
            destination: "Barcelona",
            countdown: nil,
            status: "Puntual",
            statusIsOnTime: true
        )
        let rows = NearbyStops.lineRows(metroArrivals: [], busArrivals: [], fgcArrivals: [fgc], busLines: [])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].firstTime, "Puntual")
        XCTAssertNil(rows[0].secondTime)
    }

    func testLineRowsWithNothingAreEmpty() {
        XCTAssertTrue(NearbyStops.lineRows(metroArrivals: [], busArrivals: [], fgcArrivals: [], busLines: []).isEmpty)
    }

    /// #48: FGC rows are appended one per train, so two trains of one line at
    /// the same station would show two rows with the same identity and SwiftUI
    /// would drop or reuse one of them. Metro and bus rows stay grouped per
    /// line and keep the line label as their identity.
    func testTwoFGCTrainsOfOneLineGetDistinctRowIdentities() {
        func train(id: String, destination: String) -> FavoriteArrival {
            FavoriteArrival(
                id: id,
                lineLabel: "S1",
                colorHex: "84BD00",
                textColorHex: "10220A",
                destination: destination,
                countdown: nil,
                status: "Puntual",
                statusIsOnTime: true
            )
        }

        let rows = NearbyStops.lineRows(
            metroArrivals: [],
            busArrivals: [],
            fgcArrivals: [
                train(id: "S1-GR-1", destination: "Terrassa"),
                train(id: "S1-GR-2", destination: "Sabadell"),
            ],
            busLines: []
        )

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(Set(rows.map(\.id)).count, 2, "two rows of one line must not share an id")
        XCTAssertEqual(Set(rows.map(\.lineLabel)), ["S1"], "the badge still reads the line")
    }

    func testMetroTimeTextWithoutCountdownIsDash() {
        XCTAssertEqual(NearbyStops.timeText(seconds: nil), "—")
        XCTAssertEqual(NearbyStops.timeText(seconds: 30), "ara")
        XCTAssertEqual(NearbyStops.timeText(seconds: 130), "2 min")
    }
}
