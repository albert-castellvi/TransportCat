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
        effectType: String? = nil,
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
            effectCode: effectCode,
            effectType: effectType
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

    // MARK: - Effect type and severity (S5)

    func testEffectTypeIsParsedFromCategories() throws {
        let old = try AlertParser.alerts(from: Fixtures.data("alerts"))
        // PP1 closes the line between stations: a traffic disruption.
        XCTAssertEqual(try XCTUnwrap(old.first { $0.id == "228295" }).effectType, "TRAFFIC")
        // PP2 closes corridors: infrastructure, not a service interruption.
        XCTAssertEqual(try XCTUnwrap(old.first { $0.id == "224755" }).effectType, "INFRASTRUCTURE")

        let live = try liveAlerts()
        // Every alert of the live capture is a facility-level one.
        XCTAssertEqual(live.count, 9)
        for alert in live {
            XCTAssertEqual(alert.effectType, "INFRASTRUCTURE", "unexpected effect type on \(alert.id)")
        }
        // 224755 appears in both captures and keeps decoding the same way.
        XCTAssertEqual(try XCTUnwrap(live.first { $0.id == "224755" }).effectType, "INFRASTRUCTURE")
    }

    func testSeverityIsServiceOnlyForTrafficAlerts() throws {
        let old = try AlertParser.alerts(from: Fixtures.data("alerts"))
        XCTAssertEqual(try XCTUnwrap(old.first { $0.id == "228295" }).severity, .service)
        XCTAssertEqual(try XCTUnwrap(old.first { $0.id == "224755" }).severity, .facility)

        for alert in try liveAlerts() {
            XCTAssertEqual(alert.severity, .facility, "unexpected severity on \(alert.id)")
        }
        // The comparison is case-insensitive and tolerates an absent type.
        XCTAssertEqual(alert(id: "3001", begin: nil, end: nil, effectType: "traffic").severity, .service)
        XCTAssertEqual(alert(id: "3002", begin: nil, end: nil, effectType: nil).severity, .facility)
    }

    func testSeverityOrderingPutsServiceAboveFacility() {
        XCTAssertGreaterThan(AlertSeverity.service, .facility)
        XCTAssertLessThan(AlertSeverity.facility, .service)
        XCTAssertEqual(AlertSeverity.facility.rawValue, 0)
        XCTAssertEqual(AlertSeverity.service.rawValue, 1)
        XCTAssertEqual([AlertSeverity.facility, .service, .facility].max(), .service)
    }

    func testIsActiveCoversTheDateBoundaries() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let day: TimeInterval = 24 * 60 * 60

        // No date at all: the alert has always been and always will be active.
        XCTAssertTrue(alert(id: "4001", begin: nil, end: nil).isActive(now: now))
        XCTAssertTrue(alert(id: "4002", begin: now.addingTimeInterval(-day), end: nil).isActive(now: now))
        XCTAssertTrue(alert(id: "4003", begin: nil, end: now.addingTimeInterval(day)).isActive(now: now))
        // A begin date in the future is not active yet.
        XCTAssertFalse(alert(id: "4004", begin: now.addingTimeInterval(1), end: nil).isActive(now: now))
        // An end date in the past is no longer active.
        XCTAssertFalse(alert(id: "4005", begin: nil, end: now.addingTimeInterval(-1)).isActive(now: now))
        // Both boundaries are inclusive: beginning now and ending now are active.
        XCTAssertTrue(alert(id: "4006", begin: now, end: nil).isActive(now: now))
        XCTAssertTrue(alert(id: "4007", begin: nil, end: now).isActive(now: now))
        XCTAssertTrue(alert(id: "4008", begin: now, end: now).isActive(now: now))
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
        // PP2 (corridors closed) has no dedicated icon or title: the title is
        // the first sentence of the alert text.
        XCTAssertEqual(
            atCatalunya.title,
            "A partir d'avui,i fins al 30 de desembre, els passadissos que…"
        )
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

    // MARK: - Bus alert kinds (S7)

    /// A bus alert as `BusAlertParser` produces it: no effect code, kind in
    /// `typeName`, affected stops by code.
    private func busAlert(
        id: String,
        typeName: String?,
        stationCodes: [Int],
        stationNames: [String] = [],
        line: String = "212",
        text: String? = nil,
        effectCode: String? = nil
    ) -> ServiceAlert {
        ServiceAlert(
            id: id,
            lineCodes: [line],
            stationNames: stationNames,
            beginDate: nil,
            endDate: nil,
            text: text,
            stationCodes: stationCodes,
            effectCode: effectCode,
            typeName: typeName
        )
    }

    private func incidents(for alerts: [ServiceAlert], at stationCode: Int = 385) -> [StationIncident] {
        let index = IncidentIndex.incidents(
            for: alerts,
            stations: [
                Station(
                    code: stationCode,
                    name: "Gran Via - Bilbao",
                    orderInLine: 1,
                    lineCode: "212",
                    latitude: 41.38000000,
                    longitude: 2.17000000,
                    id: nil,
                    accessible: nil
                ),
            ],
            lineCode: "212"
        )
        return index[stationCode] ?? []
    }

    func testStopClosedTypeNameBecomesAStopClosedIncident() {
        let incidents = incidents(for: [
            busAlert(id: "9001", typeName: "Parada anul·lada sense parada alternativa", stationCodes: [385]),
        ])
        XCTAssertEqual(incidents.map(\.kind), [.stopClosed])
        XCTAssertEqual(incidents.first?.title, "Parada anul·lada")
    }

    func testDetourTypeNameBecomesADetourIncident() {
        let incidents = incidents(for: [
            busAlert(
                id: "9002",
                typeName: "Modificació del recorregut amb anul·lació de parada/es i amb parades alternatives existents",
                stationCodes: [385]
            ),
        ])
        XCTAssertEqual(incidents.map(\.kind), [.detour])
        XCTAssertEqual(incidents.first?.title, "Recorregut modificat")
    }

    func testBusKindMatchingIgnoresCaseDiacriticsAndPunctuation() {
        // TMB spells the middle dot differently across payloads, and the case
        // and accents of the type name are not stable either.
        for typeName in ["Parada anul.lada sense parada alternativa", "PARADA ANUL·LADA", "parada anul-lada?"] {
            let incidents = incidents(for: [busAlert(id: "9003", typeName: typeName, stationCodes: [385])])
            XCTAssertEqual(incidents.first?.kind, .stopClosed, "type name \(typeName) must read as stopClosed")
        }
        // A highlighted H12 detour from the real feed never wins over its own
        // "recorregut" wording.
        let real = incidents(for: [
            busAlert(
                id: "134760",
                typeName: "Modificació del recorregut amb anul·lació de parada/es i amb parades alternatives existents",
                stationCodes: [385]
            ),
        ])
        XCTAssertEqual(real.first?.kind, .detour)
    }

    func testUnrecognisedBusTypeNameFallsBackToTheText() {
        let incidents = incidents(for: [
            busAlert(
                id: "9004",
                typeName: "Servei especial",
                stationCodes: [385],
                text: "El servei acaba a les 22 h. Més informació a la web."
            ),
        ])
        XCTAssertEqual(incidents.first?.kind, .other)
        XCTAssertEqual(incidents.first?.title, "El servei acaba a les 22 h")
    }

    func testMetroKindsAreUnchangedWhenAnEffectCodeIsPresent() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        // An effect code always wins over the type name, so a metro alert that
        // happens to carry a type name keeps its facility kind.
        let metro = [
            alert(id: "9005", begin: now, end: now, entranceNames: [], effectCode: "PP8", text: "Ascensor fora de servei"),
        ]
        let index = IncidentIndex.incidents(
            for: metro,
            stations: [station(code: 136, name: "Torras i Bages", line: "1")],
            lineCode: "1",
            now: now
        )
        XCTAssertEqual(index[136]?.map(\.kind), [.elevator])
        XCTAssertEqual(index[136]?.first?.title, "Ascensor fora de servei")
        // Bus alerts carry no effect code, so the type name decides and the
        // stop still has to be covered by the alert.
        let busWithoutTypeName = incidents(for: [busAlert(id: "9006", typeName: nil, stationCodes: [385])])
        XCTAssertEqual(busWithoutTypeName.map(\.kind), [.other])
        XCTAssertEqual(busWithoutTypeName.first?.title, "Incidència a l'estació")
    }

    func testBusAlertsFromTheRealFeedIndexThroughBusStops() throws {
        let alerts = try BusAlertParser.alerts(from: Fixtures.data("alerts-bus"))
        // A date inside the H12 detour's validity window, taken from the feed.
        let detour = try XCTUnwrap(alerts.first { $0.id == "134760" })
        let now = try XCTUnwrap(detour.beginDate).addingTimeInterval(60)
        let stop = BusStop(
            code: 385,
            name: "Gran Via - Bilbao",
            address: "",
            order: 1,
            directionID: 1,
            directionName: "Anada",
            destinationName: "Besòs Verneda",
            distanceFromPrevious: 0,
            latitude: 41.38000000,
            longitude: 2.17000000,
            routeID: 4893833
        )
        let index = IncidentIndex.incidents(
            for: alerts,
            stations: [stop.asStation(lineCode: "212")],
            lineCode: "212",
            now: now
        )
        // Only the H12 alert covers the stop, and it is a detour.
        XCTAssertEqual(index[385]?.map(\.alertID), ["134760"])
        XCTAssertEqual(index[385]?.map(\.kind), [.detour])
    }

    // MARK: - Derived title of a generic incident (S5)

    func testOtherIncidentTitleIsTheFirstSentenceOfTheText() throws {
        let alerts = try liveAlerts()
        let now = try liveNow(alerts)
        // 227008 covers Catalunya on L1 (code 126) and on L3 (code 326).
        let index = IncidentIndex.incidents(
            for: alerts,
            stations: [station(code: 126, name: "Catalunya", line: "1")],
            lineCode: "1",
            now: now
        )
        let incident = try XCTUnwrap(index[126]?.first)
        XCTAssertEqual(incident.kind, .other)
        // Cut at the first ". " (dot dropped) and then at a word boundary inside
        // 70 characters; the markup never reaches the title.
        XCTAssertEqual(
            incident.title,
            "A partir d'avui,i fins al 30 de desembre, els passadissos que…"
        )
        XCTAssertFalse(incident.title.contains("<"))
        XCTAssertFalse(incident.title.contains("\n"))
        // The full text of the incident still carries both sentences.
        XCTAssertEqual(incident.text?.hasSuffix("segueix les indicacions dels cartells a l'estació Catalunya."), true)
    }

    func testOtherIncidentTitleTruncatesTextWithoutASentenceBreak() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let longText = "Aquest avís explica una obra molt llarga sense cap punt final enlloc que permeti tallar el títol"
        let longIndex = IncidentIndex.incidents(
            for: [alert(id: "5001", begin: nil, end: nil, effectCode: "PP2", text: longText)],
            stations: [station(code: 136, name: "Torras i Bages", line: "1")],
            lineCode: "1",
            now: now
        )
        XCTAssertEqual(
            longIndex[136]?.first?.title,
            "Aquest avís explica una obra molt llarga sense cap punt final enlloc…"
        )

        // Exactly 70 characters is short enough to stay whole.
        let exactText = "Text de setanta caràcters exactes per provar el límit del títol d avís"
        let exactIndex = IncidentIndex.incidents(
            for: [alert(id: "5002", begin: nil, end: nil, effectCode: "PP2", text: exactText)],
            stations: [station(code: 136, name: "Torras i Bages", line: "1")],
            lineCode: "1",
            now: now
        )
        XCTAssertEqual(exactIndex[136]?.first?.title, exactText)
    }

    func testOtherIncidentTitleFallsBackWhenTheTextIsMissing() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let alerts = [
            alert(id: "5003", begin: nil, end: nil, effectCode: "PP2", text: nil),
            alert(id: "5004", begin: nil, end: nil, effectCode: "PP2", text: "   "),
        ]
        let index = IncidentIndex.incidents(
            for: alerts,
            stations: [station(code: 136, name: "Torras i Bages", line: "1")],
            lineCode: "1",
            now: now
        )
        XCTAssertEqual(index[136]?.map(\.title), ["Incidència a l'estació", "Incidència a l'estació"])
        XCTAssertNil(index[136]?.first?.text)
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
