import XCTest
@testable import TransportCat

/// Offline mode (spec S21): each snapshot type must survive a `DiskCache`
/// round-trip unchanged under its spec key, and the theoretical-fleet rule
/// must draw scheduled trains when the network is down while keeping today's
/// behavior when it works. Foundation-only, so the Linux harness runs it.
final class OfflineCacheTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("TransportCatOfflineCacheTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        try super.tearDownWithError()
    }

    private var cache: DiskCache { DiskCache(directory: directory) }

    // MARK: - Sample values

    private func metroStations() -> [Station] {
        [
            Station(code: 420, name: "Catalunya", orderInLine: 1, lineCode: "1",
                    latitude: 41.3871, longitude: 2.1666, id: 420, accessible: true),
            Station(code: 421, name: "Universitat", orderInLine: 2, lineCode: "1",
                    latitude: 41.3896, longitude: 2.1642, id: nil, accessible: nil),
            Station(code: 422, name: "Tetuan", orderInLine: 3, lineCode: "1",
                    latitude: 41.3920, longitude: 2.1600, id: 422, accessible: false),
        ]
    }

    private func metroGeometry() -> LineGeometry {
        LineGeometry(points: [
            GeoPoint(latitude: 41.3871, longitude: 2.1666),
            GeoPoint(latitude: 41.3896, longitude: 2.1642),
            GeoPoint(latitude: 41.3920, longitude: 2.1600),
        ])
    }

    private func busLine() -> BusLine {
        BusLine(
            code: 212, name: "H12",
            description: "Diagonal Mar / Munt de Dalt",
            origin: "la Bonanova", destination: "Can Peixau",
            colorHex: "003888", textColorHex: "FFFFFF",
            familyCode: 1, familyName: "Horitzontals", familyOrder: 2, order: 5
        )
    }

    private func busStops() -> [BusStop] {
        [
            BusStop(code: 91, name: "Bonanova", address: "Via Augusta 79", order: 1,
                    directionID: 1, directionName: "Anada", destinationName: "Can Peixau",
                    distanceFromPrevious: 0, latitude: 41.3960, longitude: 2.1490, routeID: 7),
            BusStop(code: 122, name: "Diagonal Mar", address: "Av. Diagonal Mar 2", order: 2,
                    directionID: 1, directionName: "Anada", destinationName: "Can Peixau",
                    distanceFromPrevious: 1250.5, latitude: 41.4090, longitude: 2.2100, routeID: 7),
        ]
    }

    private func busRoutes() -> [BusRoute] {
        [
            BusRoute(routeID: 7, directionID: 1, geometry: LineGeometry(points: [
                GeoPoint(latitude: 41.3960, longitude: 2.1490),
                GeoPoint(latitude: 41.4090, longitude: 2.2100),
            ])),
        ]
    }

    private func fgcLines() -> [FGCLine] {
        [
            FGCLine(code: "S1", name: "S1 Terrassa - Barcelona",
                    colorHex: "65277E", textColorHex: "FFFFFF",
                    polylines: [
                        [GeoPoint(latitude: 41.5080, longitude: 2.0060),
                         GeoPoint(latitude: 41.4006, longitude: 2.1394)],
                        [],
                    ]),
        ]
    }

    private func fgcStations() -> [FGCStation] {
        [
            FGCStation(code: "TCN", name: "Tibidabo", networkLine: 1, order: 3,
                       point: GeoPoint(latitude: 41.4229, longitude: 2.1169)),
            FGCStation(code: "QD1", name: "Sant Cugat Ruta 84", networkLine: 1, order: 4,
                       point: nil),
        ]
    }

    // MARK: - Keys (spec S21: metro-topology-<code>, bus-catalog,
    // bus-topology-<code>, fgc-topology)

    func testCacheKeysMatchTheSpec() {
        XCTAssertEqual(OfflineCache.metroTopologyKey(lineCode: "1"), "metro-topology-1")
        XCTAssertEqual(OfflineCache.metroTopologyKey(lineCode: "94"), "metro-topology-94")
        XCTAssertEqual(OfflineCache.busCatalogKey, "bus-catalog")
        XCTAssertEqual(OfflineCache.busTopologyKey(lineCode: 212), "bus-topology-212")
        XCTAssertEqual(OfflineCache.fgcTopologyKey, "fgc-topology")
        XCTAssertTrue(DiskCache.isValidKey(OfflineCache.metroTopologyKey(lineCode: "104")))
        XCTAssertTrue(DiskCache.isValidKey(OfflineCache.busTopologyKey(lineCode: 91)))
    }

    // MARK: - Metro topology round-trip

    func testMetroTopologyRoundTrip() async throws {
        let stations = metroStations()
        let geometry = metroGeometry()

        // Spec S5: the save hands back the write it spawned, so the round-trip
        // waits for the file instead of reading before it lands.
        let save = try XCTUnwrap(OfflineCache.saveMetroTopology(
            stations: stations, geometry: geometry, lineCode: "1", cache: cache
        ))
        await save.value
        XCTAssertTrue(cache.hasValue(forKey: "metro-topology-1"))

        let loaded = OfflineCache.loadMetroTopology(lineCode: "1", cache: cache)
        XCTAssertEqual(loaded?.stations, stations)
        XCTAssertEqual(loaded?.geometry, geometry)
    }

    func testMetroTopologyRoundTripWithoutGeometry() async throws {
        let stations = metroStations()
        let save = try XCTUnwrap(OfflineCache.saveMetroTopology(
            stations: stations, geometry: nil, lineCode: "94", cache: cache
        ))
        await save.value

        let loaded = OfflineCache.loadMetroTopology(lineCode: "94", cache: cache)
        XCTAssertEqual(loaded?.stations, stations)
        XCTAssertNil(loaded?.geometry)
    }

    func testMetroTopologyLinesAreIndependent() async throws {
        let save = try XCTUnwrap(OfflineCache.saveMetroTopology(
            stations: metroStations(), geometry: nil, lineCode: "1", cache: cache
        ))
        await save.value
        XCTAssertNil(OfflineCache.loadMetroTopology(lineCode: "5", cache: cache))
    }

    // MARK: - Bus catalog round-trip

    func testBusCatalogRoundTrip() {
        let lines = [busLine(), BusLine(code: 915, name: "V15", description: "",
                                       origin: "a", destination: "b",
                                       colorHex: "123456", textColorHex: "ABCDEF",
                                       familyCode: 2, familyName: "Verticals",
                                       familyOrder: 1, order: 3)]

        XCTAssertTrue(OfflineCache.saveBusCatalog(lines, cache: cache))
        XCTAssertTrue(cache.hasValue(forKey: "bus-catalog"))
        XCTAssertEqual(OfflineCache.loadBusCatalog(cache: cache), lines)
    }

    // MARK: - Bus topology round-trip

    func testBusTopologyRoundTrip() async throws {
        let stops = busStops()
        let routes = busRoutes()

        let save = try XCTUnwrap(OfflineCache.saveBusTopology(
            stops: stops, routes: routes, lineCode: 212, cache: cache
        ))
        await save.value
        XCTAssertTrue(cache.hasValue(forKey: "bus-topology-212"))

        let loaded = OfflineCache.loadBusTopology(lineCode: 212, cache: cache)
        XCTAssertEqual(loaded?.stops, stops)
        XCTAssertEqual(loaded?.routes, routes)
    }

    // MARK: - FGC topology round-trip

    func testFGCTopologyRoundTrip() async throws {
        let lines = fgcLines()
        let stations = fgcStations()

        let save = try XCTUnwrap(OfflineCache.saveFGCTopology(lines: lines, stations: stations, cache: cache))
        await save.value
        XCTAssertTrue(cache.hasValue(forKey: "fgc-topology"))

        let loaded = OfflineCache.loadFGCTopology(cache: cache)
        XCTAssertEqual(loaded?.lines, lines)
        XCTAssertEqual(loaded?.stations, stations)
    }

    /// #75: the offline copy must carry the station accessibility, or every
    /// FGC station loses its accessibility section when the app starts offline.
    func testFGCTopologyRoundTripKeepsWheelchairBoarding() async throws {
        let stations = [
            FGCStation(
                code: "GR",
                name: "Gràcia",
                networkLine: 1,
                order: 1,
                point: GeoPoint(latitude: 41.3991, longitude: 2.1527),
                wheelchairBoarding: 1
            ),
            FGCStation(
                code: "PR",
                name: "Provença",
                networkLine: 1,
                order: 2,
                point: nil,
                wheelchairBoarding: 2
            ),
        ]

        let save = try XCTUnwrap(OfflineCache.saveFGCTopology(
            lines: fgcLines(), stations: stations, cache: cache
        ))
        await save.value

        let loaded = OfflineCache.loadFGCTopology(cache: cache)
        XCTAssertEqual(loaded?.stations.map(\.wheelchairBoarding), [1, 2])
    }

    // MARK: - Background saves (spec S5)

    /// Spec S5: the topology saves of the three maps hand back the write they
    /// run off the caller's actor. Waiting on it lands the file, and a key that
    /// cannot address a file spawns nothing (the same silent refusal the
    /// synchronous save had).
    func testBackgroundSavesWaitableAndKeyValidated() async throws {
        let save = try XCTUnwrap(OfflineCache.saveMetroTopology(
            stations: metroStations(), geometry: metroGeometry(), lineCode: "2", cache: cache
        ))
        await save.value
        XCTAssertTrue(cache.hasValue(forKey: "metro-topology-2"))

        XCTAssertNil(OfflineCache.saveMetroTopology(
            stations: metroStations(), geometry: nil, lineCode: "../escape", cache: cache
        ))
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        XCTAssertFalse(names.contains { $0.contains("escape") })
    }

    // MARK: - Missing and corrupt values

    func testLoadOfMissingKeysReturnsNil() {
        XCTAssertNil(OfflineCache.loadMetroTopology(lineCode: "1", cache: cache))
        XCTAssertNil(OfflineCache.loadBusCatalog(cache: cache))
        XCTAssertNil(OfflineCache.loadBusTopology(lineCode: 212, cache: cache))
        XCTAssertNil(OfflineCache.loadFGCTopology(cache: cache))
    }

    func testCorruptPayloadsLoadAsNilAndNeverThrow() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for key in ["metro-topology-1", "bus-catalog", "bus-topology-212", "fgc-topology"] {
            try Data("not json".utf8).write(to: directory.appendingPathComponent("\(key).json"))
        }

        XCTAssertNil(OfflineCache.loadMetroTopology(lineCode: "1", cache: cache))
        XCTAssertNil(OfflineCache.loadBusCatalog(cache: cache))
        XCTAssertNil(OfflineCache.loadBusTopology(lineCode: 212, cache: cache))
        XCTAssertNil(OfflineCache.loadFGCTopology(cache: cache))
    }

    func testSavingOverwritesThePreviousSnapshot() {
        OfflineCache.saveBusCatalog([busLine()], cache: cache)
        let updated = busLine()
        // BusLine keeps its fields; re-starring a line changes the catalog, and
        // a reload must show the newest write, not the first one.
        OfflineCache.saveBusCatalog([busLine(), updated], cache: cache)
        XCTAssertEqual(OfflineCache.loadBusCatalog(cache: cache)?.count, 2)
    }

    // MARK: - Theoretical fleet rule (spec S21 item 4)

    func testRuleDrawsTheoreticalFleetWhenOffline() {
        // The required offline case: a full live feed that suddenly has no
        // network still draws the timetable instead of freezing on stale
        // trains or an empty map.
        XCTAssertTrue(FleetSourceRule.useTheoreticalFleet(
            isFeedEmpty: false, isOffline: true, hasSchedule: true, hasEngine: true
        ))
        // Offline and the feed was never non-empty (L9N-style lines): true too.
        XCTAssertTrue(FleetSourceRule.useTheoreticalFleet(
            isFeedEmpty: true, isOffline: true, hasSchedule: true, hasEngine: true
        ))
    }

    func testRuleKeepsTheExistingEmptyFeedBehaviorWhenOnline() {
        // Online with live arrivals: drawn from the feed, unchanged.
        XCTAssertFalse(FleetSourceRule.useTheoreticalFleet(
            isFeedEmpty: false, isOffline: false, hasSchedule: true, hasEngine: true
        ))
        // Online with an empty feed but a timetable and a geometry: the
        // schedule S6 rule still applies.
        XCTAssertTrue(FleetSourceRule.useTheoreticalFleet(
            isFeedEmpty: true, isOffline: false, hasSchedule: true, hasEngine: true
        ))
    }

    func testRuleNeedsBothScheduleAndGeometry() {
        XCTAssertFalse(FleetSourceRule.useTheoreticalFleet(
            isFeedEmpty: false, isOffline: true, hasSchedule: false, hasEngine: true
        ))
        XCTAssertFalse(FleetSourceRule.useTheoreticalFleet(
            isFeedEmpty: false, isOffline: true, hasSchedule: true, hasEngine: false
        ))
    }
}
