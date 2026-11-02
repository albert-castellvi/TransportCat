import XCTest
@testable import TransportCat

/// `NextArrivalsFetcher` (spec S15) pure rules: the soonest-first selection
/// per operator and the spoken dialog. The network legs are thin wrappers over
/// `TMBClient` and `FGCClient` and stay for the simulator.
final class NextArrivalsFetcherTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Helpers

    private func place(
        kind: PlaceKind,
        code: String = "128",
        name: String = "Catalunya",
        lines: [String] = ["L1", "L3"]
    ) -> Place {
        Place(
            kind: kind,
            code: code,
            name: name,
            position: GeoPoint(latitude: 41.385, longitude: 2.170),
            lineCodes: lines,
            accessible: nil
        )
    }

    private func arrival(line: String, destination: String, seconds: Int?) -> Arrival {
        Arrival(
            stationCode: 128,
            lineCode: line,
            destination: destination,
            seconds: seconds,
            rawText: seconds.map { Arrival.countdownText(seconds: $0) } ?? "—"
        )
    }

    private func busArrival(
        line: Int,
        name: String,
        destination: String,
        seconds: Int
    ) -> BusArrival {
        BusArrival(
            stopCode: 21201,
            lineCode: line,
            lineName: name,
            directionID: 1,
            trajectCode: "0011",
            destination: destination,
            seconds: seconds,
            busID: nil,
            rampStatus: nil
        )
    }

    private func train(
        id: String,
        lineCode: String,
        destinationName: String?,
        destinationCode: String = "BLG",
        stoppedAt: String? = nil,
        nextStops: [String] = []
    ) -> FGCTrain {
        FGCTrain(
            id: id,
            lineCode: lineCode,
            direction: "A",
            originCode: "SCO",
            destinationCode: destinationCode,
            destinationName: destinationName,
            position: GeoPoint(latitude: 41.380, longitude: 2.120),
            nextStopCodes: nextStops,
            isOnTime: true,
            stoppedAtStopCode: stoppedAt,
            unitType: nil,
            occupancy: []
        )
    }

    // MARK: - metroSelection

    func testMetroSelectionSortsBySecondsAndCapsAtThree() {
        let picked = NextArrivalsFetcher.metroSelection(
            [
                arrival(line: "L3", destination: "Zona Universitària", seconds: 180),
                arrival(line: "L1", destination: "Fondo", seconds: 90),
                arrival(line: "L1", destination: "Bellvitge", seconds: 300),
                arrival(line: "L2", destination: "Badalona", seconds: 600),
            ],
            now: now
        )
        XCTAssertEqual(picked.map(\.line), ["L1", "L3", "L1"])
        XCTAssertEqual(picked.map(\.destination), ["Fondo", "Zona Universitària", "Bellvitge"])
        XCTAssertEqual(picked[0].date, now.addingTimeInterval(90))
    }

    func testMetroSelectionPutsMissingSecondsLastAndAtNow() {
        let picked = NextArrivalsFetcher.metroSelection(
            [
                arrival(line: "L1", destination: "Fondo", seconds: nil),
                arrival(line: "L3", destination: "Can Valero", seconds: 240),
            ],
            now: now
        )
        XCTAssertEqual(picked.map(\.line), ["L3", "L1"])
        XCTAssertEqual(picked[1].date, now)
    }

    func testMetroSelectionFallsBackToDashForEmptyDestination() {
        let picked = NextArrivalsFetcher.metroSelection(
            [arrival(line: "L1", destination: "", seconds: 60)],
            now: now
        )
        XCTAssertEqual(picked[0].destination, "—")
    }

    // MARK: - busSelection

    func testBusSelectionSortsAndMapsLabelAndDate() {
        let picked = NextArrivalsFetcher.busSelection(
            [
                busArrival(line: 212, name: "H12", destination: "La Sagrera", seconds: 120),
                busArrival(line: 7, name: "V13", destination: "Zona Universitària", seconds: 30),
            ],
            now: now
        )
        XCTAssertEqual(picked.map(\.line), ["V13", "H12"])
        XCTAssertEqual(picked[0].date, now.addingTimeInterval(30))
        XCTAssertEqual(picked[1].destination, "La Sagrera")
    }

    // MARK: - fgcSelection

    func testFgcSelectionPutsStoppedTrainsFirstThenAnnouncedByCloseness() {
        let picked = NextArrivalsFetcher.fgcSelection(
            [
                train(id: "b", lineCode: "L1-4", destinationName: "Terrassa", nextStops: ["BLG", "GR"]),
                train(id: "a", lineCode: "S1", destinationName: "Sabadell", stoppedAt: "GR"),
                train(id: "c", lineCode: "L1-3", destinationName: nil, destinationCode: "MMG", nextStops: ["GR"]),
            ],
            stationCode: "GR",
            now: now
        )
        XCTAssertEqual(picked.map(\.line), ["S1", "L1-3", "L1-4"])
        XCTAssertEqual(picked.map(\.destination), ["Sabadell", "MMG", "Terrassa"])
        XCTAssertEqual(picked.map(\.date), [now, now, now], "FGC publishes no minutes")
    }

    func testFgcSelectionIgnoresTrainsNotComingToTheStation() {
        let picked = NextArrivalsFetcher.fgcSelection(
            [train(id: "a", lineCode: "S1", destinationName: nil, destinationCode: "BLG", nextStops: ["SCO"])],
            stationCode: "GR",
            now: now
        )
        XCTAssertTrue(picked.isEmpty)
    }

    // MARK: - dialog

    func testDialogMetroExample() {
        let text = NextArrivalsFetcher.dialog(
            for: place(kind: .metroStation),
            arrivals: [
                NextArrival(line: "L1", destination: "Fondo", date: now.addingTimeInterval(120)),
                NextArrival(line: "L3", destination: "Zona Universitària", date: now.addingTimeInterval(300)),
            ],
            now: now
        )
        XCTAssertEqual(
            text,
            "Propers trens a Catalunya: L1 cap a Fondo en 2 min, L3 cap a Zona Universitària en 5 min"
        )
    }

    func testDialogBusPrefix() {
        let text = NextArrivalsFetcher.dialog(
            for: place(kind: .busStop, code: "21201", name: "Gran Via - Comtessa de Sobradiel", lines: ["H12"]),
            arrivals: [NextArrival(line: "H12", destination: "La Sagrera", date: now.addingTimeInterval(120))],
            now: now
        )
        XCTAssertEqual(text, "Propers busos a Gran Via - Comtessa de Sobradiel: H12 cap a La Sagrera en 2 min")
    }

    func testDialogWithoutArrivals() {
        let text = NextArrivalsFetcher.dialog(for: place(kind: .metroStation), arrivals: [], now: now)
        XCTAssertEqual(text, NextArrivalsFetcher.noArrivalsText)
        XCTAssertEqual(text, "No hi ha arribades previstes ara mateix.")
    }

    func testDialogCapsAtThreeArrivals() {
        let many = (1...5).map {
            NextArrival(line: "L1", destination: "Fondo \($0)", date: now.addingTimeInterval(TimeInterval($0 * 60)))
        }
        let text = NextArrivalsFetcher.dialog(for: place(kind: .metroStation), arrivals: many, now: now)
        XCTAssertEqual(text.components(separatedBy: ", ").count, 3)
    }

    func testDialogSaysAraMateixWithoutMinutes() {
        let text = NextArrivalsFetcher.dialog(
            for: place(kind: .fgcStation, code: "GR", name: "Gràcia", lines: ["S1"]),
            arrivals: [NextArrival(line: "S1", destination: "Terrassa", date: now)],
            now: now
        )
        XCTAssertEqual(text, "Propers trens a Gràcia: S1 cap a Terrassa ara mateix")
    }

    // MARK: - timeSuffix

    func testTimeSuffixRoundsUpToWholeMinutes() {
        XCTAssertEqual(NextArrivalsFetcher.timeSuffix(until: now.addingTimeInterval(45), now: now), " en 1 min")
        XCTAssertEqual(NextArrivalsFetcher.timeSuffix(until: now.addingTimeInterval(120), now: now), " en 2 min")
        XCTAssertEqual(NextArrivalsFetcher.timeSuffix(until: now.addingTimeInterval(121), now: now), " en 3 min")
    }

    func testTimeSuffixAtOrBeforeNow() {
        XCTAssertEqual(NextArrivalsFetcher.timeSuffix(until: now, now: now), " ara mateix")
        XCTAssertEqual(NextArrivalsFetcher.timeSuffix(until: now.addingTimeInterval(-30), now: now), " ara mateix")
    }
}
