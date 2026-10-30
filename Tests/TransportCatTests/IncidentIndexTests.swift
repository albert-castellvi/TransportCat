import XCTest
@testable import TransportCat

final class IncidentIndexTests: XCTestCase {
    // MARK: - Helpers

    private func liveAlerts() throws -> [ServiceAlert] {
        try AlertParser.alerts(from: Fixtures.data("alerts-live"))
    }

    /// A moment inside the live feed's validity window, derived from the feed
    /// itself: the newest begin date has already arrived and the earliest end
    /// date is still ahead. Nothing here depends on the wall clock.
    private func liveNow(_ alerts: [ServiceAlert]) throws -> Date {
        let begins = try alerts.map { try XCTUnwrap($0.beginDate) }
        let ends = try alerts.map { try XCTUnwrap($0.endDate) }
        let now = try XCTUnwrap(begins.max())
        XCTAssertLessThanOrEqual(now, try XCTUnwrap(ends.min()), "live alerts share no common active window")
        return now
    }

    private func station(code: Int, name: String, line: String, order: Int = 1) -> Station {
        Station(
            code: code,
            name: name,
            orderInLine: order,
            lineCode: line,
            latitude: 41.38000000,
            longitude: 2.17000000,
            id: nil,
            accessible: true
        )
    }

    private func alert(
        id: String,
        begin: Date?,
        end: Date?,
        line: String = "1",
        stationCodes: [Int] = [136],
        stationNames: [String] = [],
        entranceNames: [String] = [],
        effectCode: String? = "PP9",
        text: String? = nil
    ) -> ServiceAlert {
        ServiceAlert(
            id: id,
            lineCodes: [line],
            stationNames: stationNames,
            beginDate: begin,
            endDate: end,
            text: text,
            stationCodes: stationCodes,
            entranceNames: entranceNames,
            effectCode: effectCode
        )
    }

    // MARK: - Parser (S3)

    func testLiveAlertsParseStationCodesEffectsAndEntrances() throws {
        let alerts = try liveAlerts()
        XCTAssertEqual(alerts.count, 9)

        let escalator = try XCTUnwrap(alerts.first { $0.id == "228286" })
        XCTAssertEqual(escalator.lineCodes, ["1"])
        XCTAssertEqual(escalator.stationCodes, [136])
        XCTAssertEqual(escalator.effectCode, "PP9")
        // The feed sends entrance_name "ALL" when the whole station is meant.
        XCTAssertEqual(escalator.entranceNames, [])
        XCTAssertEqual(escalator.stationNames, ["Torras i Bages"])

        let accessClosed = try XCTUnwrap(alerts.first { $0.id == "228203" })
        XCTAssertEqual(accessClosed.lineCodes, ["3"])
        XCTAssertEqual(accessClosed.stationCodes, [324])
        XCTAssertEqual(accessClosed.effectCode, "PP7")
        XCTAssertEqual(accessClosed.entranceNames, ["Santa Madrona"])

        // One alert covering an interchange of two lines: two entities, so two
        // station codes and two line codes, none of them duplicated.
        let corridor = try XCTUnwrap(alerts.first { $0.id == "227008" })
        XCTAssertEqual(Set(corridor.lineCodes), ["1", "3"])
        XCTAssertEqual(Set(corridor.stationCodes), [126, 326])
        XCTAssertEqual(corridor.effectCode, "PP2")
        XCTAssertEqual(corridor.entranceNames, [])

        let elevator = try XCTUnwrap(alerts.first { $0.id == "227995" })
        XCTAssertEqual(elevator.effectCode, "PP8")
        XCTAssertEqual(elevator.stationCodes, [9445])
    }

    func testOldAlertsFixtureStillParsesUnchanged() throws {
        let alerts = try AlertParser.alerts(from: Fixtures.data("alerts"))
        XCTAssertEqual(alerts.count, 2)
        XCTAssertEqual(alerts.map(\.id), ["228295", "224755"])
        XCTAssertEqual(Set(alerts[0].lineCodes), ["2"])
        XCTAssertEqual(alerts[0].stationNames, ["La Pau", "Verneda", "Artigues | Sant Adrià", "Sant Roc", "Gorg"])
        XCTAssertEqual(alerts[1].lineCodes, ["1", "5"])
        XCTAssertEqual(alerts[1].stationNames, ["Plaça de Sants"])
        XCTAssertEqual(
            alerts[0].text,
            "Per treballs en la infraestructura, del 2 de novembre al 3 de desembre, sense servei a l'L2 entre La Pau i Gorg."
        )
        // The new fields decode from the same payload without touching the old ones.
        XCTAssertEqual(alerts[0].stationCodes, [221, 222, 223, 224, 225])
        XCTAssertEqual(alerts[0].effectCode, "PP1")
        XCTAssertEqual(alerts[1].stationCodes, [120, 517])
    }

    // MARK: - Index (S3)

    func testLineOneIndexKeepsOnlyStationsWithIncidents() throws {
        let alerts = try liveAlerts()
        let now = try liveNow(alerts)
        let stations = [
            station(code: 126, name: "Catalunya", line: "1", order: 1),
            station(code: 136, name: "Torras i Bages", line: "1", order: 2),
            station(code: 111, name: "Hospital de Bellvitge", line: "1", order: 3),
        ]

        let index = IncidentIndex.incidents(for: alerts, stations: stations, lineCode: "1", now: now)

        // 111 has no alert, so it is absent rather than mapped to an empty list.
        XCTAssertEqual(Set(index.keys), [126, 136])
        XCTAssertEqual(try XCTUnwrap(index[136]).map(\.kind), [.escalator])
        XCTAssertEqual(try XCTUnwrap(index[126]).map(\.kind), [.other])

        let atTorras = try XCTUnwrap(index[136]?.first)
        XCTAssertEqual(atTorras.id, "228286-136")
        XCTAssertEqual(atTorras.alertID, "228286")
        XCTAssertEqual(atTorras.title, "Escala mecànica fora de servei")
        XCTAssertNil(atTorras.entrance)
        XCTAssertEqual(atTorras.text?.hasPrefix("Fins al 17 de novembre"), true)

        let atCatalunya = try XCTUnwrap(index[126]?.first)
        XCTAssertEqual(atCatalunya.id, "227008-126")
        // PP2 (corridors closed) has no dedicated icon or title.
        XCTAssertEqual(atCatalunya.title, "Incidència a l'estació")
    }

    func testInterchangeAlertCoversBothLinesWithoutLeakingCodes() throws {
        let alerts = try liveAlerts()
        let now = try liveNow(alerts)
        let stations = [
            station(code: 324, name: "Drassanes", line: "3", order: 1),
            station(code: 326, name: "Catalunya", line: "3", order: 2),
        ]

        let index = IncidentIndex.incidents(for: alerts, stations: stations, lineCode: "3", now: now)

        XCTAssertEqual(Set(index.keys), [324, 326])
        // Alert 227008 covers Catalunya on L1 (code 126) and on L3 (code 326):
        // only the L3 station code of the list is reachable.
        XCTAssertFalse(index.keys.contains(126))
        XCTAssertEqual(try XCTUnwrap(index[326]).map(\.alertID), ["227008"])
        XCTAssertEqual(try XCTUnwrap(index[324]).map(\.kind), [.accessClosed])

        let closedAccess = try XCTUnwrap(index[324]?.first)
        XCTAssertEqual(closedAccess.title, "Accés tancat: Santa Madrona")
        XCTAssertEqual(closedAccess.entrance, "Santa Madrona")
        XCTAssertEqual(closedAccess.id, "228203-324")
    }

    func testIncidentTextIsPlainTextWithoutHtml() throws {
        let alerts = try liveAlerts()
        let now = try liveNow(alerts)
        let stations = [station(code: 9445, name: "Can Zam", line: "94")]

        let index = IncidentIndex.incidents(for: alerts, stations: stations, lineCode: "94", now: now)
        let incident = try XCTUnwrap(index[9445]?.first)
        XCTAssertEqual(incident.kind, .elevator)
        XCTAssertEqual(incident.title, "Ascensor fora de servei")
        // "<br>" became a space; the newline in the payload collapsed too.
        XCTAssertEqual(
            incident.text,
            "Els ascensors de Can Zam es troben fora de servei per renovació. "
                + "Si els necessites per accedir al metro, pots utilitzar les línies de bus B20 o M27 "
                + "que t'apropen a Singuerlín."
        )
        // Every live alert, on every line it touches: no incident text may
        // keep a single markup character.
        var entries: [StationIncident] = []
        for line in Set(alerts.flatMap(\.lineCodes)) {
            let codes = Set(alerts.filter { $0.lineCodes.contains(line) }.flatMap(\.stationCodes))
            let stations = codes.map { station(code: $0, name: "", line: line) }
            entries += IncidentIndex.incidents(for: alerts, stations: stations, lineCode: line, now: now)
                .values.flatMap { $0 }
        }
        XCTAssertGreaterThanOrEqual(entries.count, 9)
        for entry in entries {
            XCTAssertFalse(entry.text?.contains("<") ?? false, "raw HTML left in \(entry.id)")
            XCTAssertFalse(entry.text?.contains(">") ?? false, "raw HTML left in \(entry.id)")
            XCTAssertFalse(entry.text?.contains("<br") ?? false, "unterminated tag left in \(entry.id)")
        }
    }

    func testHtmlTagsInAnyCaseAreStripped() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let alerts = [
            alert(id: "9001", begin: nil, end: nil, text: "Primera línia<BR/>segona   línia\n<p>tercera</p>")
        ]
        let index = IncidentIndex.incidents(
            for: alerts,
            stations: [station(code: 136, name: "Torras i Bages", line: "1")],
            lineCode: "1",
            now: now
        )
        XCTAssertEqual(index[136]?.first?.text, "Primera línia segona línia tercera")
    }

    func testInactiveAlertsAreIgnored() throws {
        let alerts = try liveAlerts()
        let now = try liveNow(alerts)
        let day: TimeInterval = 24 * 60 * 60
        let probes = [
            alert(id: "1001", begin: now.addingTimeInterval(day), end: now.addingTimeInterval(2 * day)),
            alert(id: "1002", begin: now.addingTimeInterval(-2 * day), end: now.addingTimeInterval(-day)),
            // No begin date counts as already started; no end date means ongoing.
            alert(id: "1003", begin: nil, end: nil),
            alert(id: "1004", begin: now.addingTimeInterval(-day), end: nil),
        ]
        let stations = [station(code: 136, name: "Torras i Bages", line: "1")]

        let index = IncidentIndex.incidents(for: probes, stations: stations, lineCode: "1", now: now)
        XCTAssertEqual(index[136]?.map(\.alertID), ["1003", "1004"])
    }

    /// Incidents of one station are listed by alert id ascending.
    func testStationIncidentsAreOrderedByAlertId() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let alerts = [
            alert(id: "1002", begin: now, end: nil, effectCode: "PP8"),
            alert(id: "1001", begin: now, end: nil, effectCode: "PP9"),
        ]
        let index = IncidentIndex.incidents(
            for: alerts,
            stations: [station(code: 136, name: "Torras i Bages", line: "1")],
            lineCode: "1",
            now: now
        )
        XCTAssertEqual(index[136]?.map(\.alertID), ["1001", "1002"])
        XCTAssertEqual(index[136]?.map(\.kind), [.escalator, .elevator])
    }

    func testAccessClosedWithoutEntranceUsesThePlainTitle() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let alerts = [alert(id: "2001", begin: now, end: nil, entranceNames: [], effectCode: "PP7")]
        let index = IncidentIndex.incidents(
            for: alerts,
            stations: [station(code: 136, name: "Torras i Bages", line: "1")],
            lineCode: "1",
            now: now
        )
        XCTAssertEqual(index[136]?.first?.title, "Accés tancat")
        XCTAssertNil(index[136]?.first?.entrance)
    }
}
