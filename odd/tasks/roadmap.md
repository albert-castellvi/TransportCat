# Roadmap P1-P3
Objective: ship every roadmap item (P1 global mode, incidents on map, follow, location/nearby, favorites, search; P2 Live Activity, arrival notifications, incident alerts, widgets, Siri/Shortcuts; P3 planner, accessibility, FGC occupancy, first/last train and timetables, interchanges, Apple Watch, offline) to TestFlight.
Branches: `feat/roadmap-a` (phase A, P1), `feat/roadmap-b` (phase B, app-only P2/P3), `feat/roadmap-c` (phase C, new targets and CI signing); one PR per phase, squash-merged to main, and each merge uploads to TestFlight. Test runner: XCTest in CI (`Generate project and run tests (simulator)`); Foundation-only Core logic also runs in the local Linux SwiftPM scratch harness. SwiftUI compiles only in CI.

## Specs
Conventions for every spec: code, comments and identifiers are in English; user-facing strings are in Catalan; animation goes through `AppMotion` (Reduce Motion respected); accessibility labels are in Catalan; existing metro/bus/FGC behavior, texts and tests stay (no regression); no new third-party dependency; TMB credentials never reach logs or Sentry. TMB API reference: `DOC-TMB/{transit,imetro,ibus,planer,static}.json` (OpenAPI).

### Shared infrastructure (T1)
- S1 Place model. `Place: Codable, Hashable, Identifiable` with `kind` (`metroStation`, `busStop`, `fgcStation`), `code`, `name`, `position: GeoPoint`, `lineCodes: [String]`, `accessible: Bool?`, and `id = "<kind>:<code>"`. Pure helpers in `PlaceIndex`:
  - `search(query, places, limit)`: case- and diacritic-insensitive; prefix matches rank before substring matches.
  - `nearest(to:places:limit:maxDistance:)`: returns places with their distance in meters.
  - `interchanges(for:places:radius: 250)`: other places within the radius, plus metro stations sharing the same name.
- S2 Place catalog. `PlaceCatalogStore.shared` (`@MainActor @Observable`) loads:
  - every metro station of all 11 `MetroLine`s, with their line codes and `accessible`;
  - every TMB bus stop with its lines;
  - every FGC station, from the FGC topology.
  The endpoints are chosen from `DOC-TMB`. All-network endpoints are preferred over one call per line. Loaded once per launch, then persisted with S3. A failed load falls back to the cached copy.
- S3 Disk cache. `DiskCache` stores Codable values as JSON under `Caches/Network/<key>.json` with atomic writes and silent failures, and records a save date so callers can check age.
- S4 Favorites. `FavoritesStore.shared` (`@Observable`) holds favorite places in UserDefaults key `favoritePlaces.v1` and favorite metro/FGC lines (`FavoriteLine { operator: "metro"|"fgc", code }`) in key `favoriteLines.v1`. Its API is `toggle`/`isFavorite` for both. Bus line favorites stay in the existing `busFavorites` key of `BusCatalogStore`, so they are not duplicated.
- S5 Router. `AppRouter.shared` (`@MainActor @Observable`):
  - holds `selectedTab: AppTab` (`map`, `lines`, `alerts`, `explore`);
  - holds `pendingFocus: Destination?`, where `Destination` is `.place(Place)`, `.line(operator: String, code: String)` or `.vehicle(operator: String, lineCode: String, vehicleID: String)`;
  - `open(_:)` writes the needed `appMode` and selected line, switches to the map tab and sets `pendingFocus`;
  - the screen that handles a focus clears it.
- S6 Location. `LocationService.shared` (`@MainActor @Observable`, CoreLocation, when-in-use only) exposes `location: GeoPoint?` and `authorization`, and has `requestWhenInUse()`, `start()` and `stop()`. Info.plist gets `NSLocationWhenInUseUsageDescription` = "TransportCat fa servir la teva ubicació per mostrar-te les estacions i parades properes."
- S7 Incident sheet. `IncidentSheet(alerts: [ServiceAlert], title: String)` in `Features/Shared` lists each alert with its affected lines, stations, dates, effect and cleaned text. Detents are medium and large. It is reused by every map that marks incidents.

### Phase A — P1
- S8 Global mode. `AppMode.global` (raw value "global", label "Tot"). The selector reads "Metro | Bus | FGC | Tot".
  - **Mapa tab:** `GlobalMapScreen` draws:
    - every metro line in its color;
    - every FGC line;
    - the route polylines of the user's favorite bus lines;
    - metro live trains of all lines and FGC live trains.
  - **Operator filter:** Metro / Bus / FGC toggle chips, persisted in key `globalOperators`.
  - **Zoom levels:** when the camera span is wider than 0.25°, only lines are drawn. Between 0.08° and 0.25°, stations are added as dots. Below 0.08°, vehicles with labels are added.
  - **Polling:** a single `GlobalNetworkState` drives every metro line with one 30 s poll loop and one 10 Hz ticker, only while global mode is visible. The existing `LineState` logic is reused, never re-implemented. FGC data comes from `FGCNetworkState.shared`, whose poller runs in FGC and global modes. Bus vehicles are not drawn in global mode, to protect the TMB quota.
  - **Incidents:** affected metro stations show a warning marker that opens `IncidentSheet`.
  - **Vehicle tap:** calls `AppRouter.open(.vehicle(...))`, which switches to that operator's map with the follow sheet open (S10).
  - **Línies tab:** a list of all lines grouped by operator (Metro, FGC, favorite Bus lines). Tapping a line calls `AppRouter.open(.line(...))`.
- S9 Incidents on the map. On the metro map:
  - stations with an active incident (via `IncidentIndex`) get a red warning marker;
  - each run of consecutive affected stations is overlaid with a red dashed polyline;
  - a tap opens `IncidentSheet` (e.g. "L2 de X a Y tallada", with the reason).
  On the bus map, stops with incidents get a warning marker that opens `IncidentSheet`.
- S10 Follow. Tapping a metro train or a bus marker opens a vehicle sheet (detents medium and large) with:
  - line badge, destination or direction, next station/stop and its arrival;
  - a "Seguir" / "Deixar de seguir" button that uses the same mechanics as `FGCMapScreen`: the camera re-centers on every motion update and stops when the user pans or the sheet closes.
  `AppRouter` `.vehicle` focus opens that sheet with follow on, on the metro, bus and FGC maps.
- S11 Location on maps. The metro, bus, FGC and global maps show `UserAnnotation()` and a `MapUserLocationButton()` when authorized. When authorization is not determined, a location button asks for permission through `LocationService`. A denied permission never blocks the map. Maps handle `AppRouter` `.place` focus by centering on the place and opening its sheet, and `.line` focus by selecting the line.
- S12 Explora tab. A 4th tab "Explora" (SF Symbol `magnifyingglass`) with `.searchable` prompt "Cerca estacions, parades o línies". It has:
  - **Search:** places via `PlaceIndex.search`, metro lines, FGC lines and bus lines via `BusCatalog.search`. Selecting a result calls `AppRouter.open`.
  - **"Preferits":** favorite places with their next 2 arrivals, refreshed every 30 s while visible, and favorite lines.
  - **"A prop":** the 10 nearest places within 1 km, with distance and walking minutes (80 m/min). Without permission, it shows a button "Activa la ubicació".
  - **Place detail:** a metro station opens the existing station sheet, a bus stop opens `BusStopSheet`, and an FGC station opens a new `FGCStationSheet` with the trains heading to it. Each has a "Veure al mapa" action.
  - **Stars:** a star toggle (S4) on the station sheet, bus stop sheet and FGC station sheet. Line favorites are toggled from a search result's context menu.

### Phase B — app-only P2/P3
- S13 Arrival notifications. `ArrivalReminder.shared.schedule(id: String, title: String, body: String, at: Date)` and `cancel(id:)` in `TransportCat/Core/Notifications/ArrivalReminder.swift` (local `UNUserNotificationCenter`; permission is asked on first use).
  - Every arrival row in the station sheet and bus stop sheet has a menu "Avisa'm" with options 1, 3 and 5 minutes before the arrival.
  - The notification body reads "El <línia> cap a <destí> arriba a <parada> en <n> min".
  - An option whose time has already passed is disabled.
  - Foreground notifications are shown as banners.
- S14 Incident alerts for my lines. `IncidentWatcher`:
  - compares metro and bus alerts against the favorite lines (S4 and `busFavorites`) and notifies each new alert id once; seen ids are persisted;
  - runs on every 60 s alerts poll and in a `BGAppRefreshTask` `cat.transport.app.alerts-refresh` (Info.plist `UIBackgroundModes` `fetch` plus `BGTaskSchedulerPermittedIdentifiers`);
  - has a toggle "Avisa'm de les incidències de les meves línies" at the top of `AlertsScreen`, off by default.
  Without a backend this is best effort, because iOS decides the background frequency.
- S15 Siri / Shortcuts. App Intents in `TransportCat/Intents/`, written so the widget extension (S20) can compile them too:
  - `PlaceEntity` (backed by S1/S2, with a string search query);
  - `NextArrivalsIntent` "Properes arribades", which returns a spoken dialog and snippet with the next 3 arrivals;
  - `AppShortcutsProvider` phrases in Catalan, each containing `\(.applicationName)` (e.g. "Propers trens a \(.applicationName)").
- S16 Planner. Uses the TMB planner (`DOC-TMB/planer.json`). An entry "Planifica un viatge" in Explora opens a screen with:
  - **Origin:** "La meva ubicació" or a searched place. **Destination:** a searched place. **Time:** depart now / at a time.
  - **Itinerary list:** total minutes, transfers, walking minutes, and leg badges in line colors.
  - **Detail:** legs with stops, plus a map of the leg polylines.
  The TMB encoded polyline decoder and the response parser are pure, tested Core code.
- S17 Accessibility info. The metro station sheet shows "Accessible" / "No accessible" (`Station.accessible`) and, when `DOC-TMB` offers access/elevator data for the station, the list of accesses with their accessibility type. The FGC station sheet shows the GTFS `wheelchair_boarding` state. Bus stop arrivals keep their ramp state. Explora results show a wheelchair symbol for accessible places.
- S18 FGC occupancy. The FGC train sheet keeps its per-car bars. FGC lines-screen badges and the global/FGC train accessibility labels add an occupancy summary: "Ocupació baixa / mitjana / alta" for a mean below 40 %, 40–70 % and above 70 %. It is omitted when FGC publishes no occupancy.
- S19 Timetables, first/last, interchanges.
  - **Timetables:** the metro station sheet and bus stop sheet show "Primer i últim" per direction for today (min/max start from the schedule pack day types, adjusted by the stop's pattern offset) and an "Horari" disclosure listing today's theoretical departures from now to the end of service.
  - **Interchanges:** the station sheet shows "Correspondències": other metro lines at the station and FGC stations within 250 m (S1), as tappable badges that call `AppRouter.open`.
- S21 Offline mode. Metro topology (stations and geometry per line), the bus catalog, bus stops/routes per line and the FGC topology are persisted with S3 on each successful load. On failure they load from the cache.
  - A `ConnectivityMonitor` (`NWPathMonitor`) drives a banner on the Mapa tab "Sense connexió · dades desades i horaris teòrics".
  - While offline, the metro map draws theoretical trains from the schedule pack (the existing `TheoreticalFleet`) instead of an empty map.

### Phase C — new targets and CI
- S20 Widgets and Live Activity. A widget extension target `TransportCatWidgets` (bundle id `cat.transport.app.widgets`, iOS 17) embedded in the app.
  - **Widget "Properes arribades":** small, medium and lock-screen rectangular families. It is configured by an AppIntent with a `PlaceEntity` (S15), fetches arrivals itself, and refreshes every 5 min.
  - **Live Activity:** `ArrivalActivityAttributes` (shared Core file) carries line, colors, place and destination; its content state carries the arrival date. The UI covers the lock screen and the Dynamic Island compact/expanded/minimal views, with a `Text(timerInterval:)` countdown.
  - **Start and update:** arrival rows in the station sheet and bus stop sheet get "Segueix en directe", which starts the activity. The app updates it on each refresh while running, and it ends 2 min after the arrival.
  - Info.plist gets `NSSupportsLiveActivities`.
  - No App Groups: the extension keeps its own cache, and TMB credentials are injected into its Info.plist the same way as the app's.
- S22 Apple Watch. A watchOS 10 app target `TransportCatWatch` (bundle id `cat.transport.app.watchkitapp`, `WKCompanionAppBundleIdentifier` `cat.transport.app`) embedded in the app.
  - It shows the favorite places synced from the phone via WatchConnectivity application context, and their next arrivals fetched by the watch itself.
  - It has a search by name.
  - TMB credentials are injected like the app's.
- S23 CI signing for three bundle ids. `.github/scripts/provision-signing.sh` and the signed job ensure the App ID and an `IOS_APP_STORE` profile for each of `cat.transport.app`, `cat.transport.app.widgets` and `cat.transport.app.watchkitapp`, all bound to the same distribution certificate (created at most once per run).
  - The archive passes per-target code-sign variables (as `TRANSPORTCAT_*` does today).
  - `exportOptions.plist` maps all three bundle ids.
  - The simulator test job still passes.
  - No secret value is ever printed.

Out of scope: a push backend (notifications are local or best-effort background), Rodalies, App Groups, refactoring metro/bus onto `MapLineLayer`.

## Tasks
| ID | Specs | Phase | Route | Model / effort | Status | Commit |
|----|-------|-------|-------|----------------|--------|--------|
| T1 | S1-S7 | A | delegated (opencode TUI) | nan/deepseek-v4-flash, medium | done (38 Linux XCTest green, parent re-ran) | 52fdd65 |
| T2 | S8 (+RootView Explora tab wiring) | A | delegated, parallel after T1 | nan/qwen3.8-flash, medium | done (9 Linux tests; swiftc -parse OK; compile in CI) | f57e832 |
| T3 | S12 | A | delegated, parallel after T1 | nan/qwen3.8-flash, medium | done (14 Linux tests; swiftc -parse OK; compile in CI) | 0c91114 |
| T4 | S9-S11 metro map | A | delegated, parallel after T1 | nan/qwen3.8-flash, medium | done (18 Linux tests; swiftc -parse OK; compile in CI) | 6476f42 |
| T5 | S10-S11 bus + FGC maps | A | delegated, parallel after T1 | nan/qwen3.8-flash, medium | done (parse only; swiftc -parse OK; compile in CI) | 9d4dd8d |
| T6 | S13 UI hooks, S17-S19 | B | delegated, parallel | nan/qwen3.8-flash, medium | pending | |
| T7 | S13 core, S14, S15 | B | delegated, parallel | nan/deepseek-v4-flash, medium | pending | |
| T8 | S16 | B | delegated, parallel | nan/qwen3.8-flash, medium | pending | |
| T9 | S21 | B | delegated, parallel | nan/deepseek-v4-flash, medium | pending | |
| T10 | S20 | C | delegated | nan/qwen3.8-flash, medium | pending | |
| T11 | S22 | C | delegated, after T10 (shares project.yml) | nan/qwen3.8-flash, medium | pending | |
| T12 | S23 | C | delegated, parallel with T10 | nan/deepseek-v4-flash, high (Risk item 5) | pending | |
| CI-fix | compile fixes from CI logs per phase | A-C | delegated | nan/deepseek-v4-flash, low | as needed | |

## Log
- L1 (2026-11-02) "no pares hasta completar TODO el listado i enviar a testfligh"
- L2 (2026-11-02) "delegalo en opencode eh?" / "opus orquestracion pura": Opus only orchestrates, and every task goes to opencode TUI workers on NaN models.
- L3 (2026-11-02) The list is the roadmap delivered earlier (P1-P3). L1 is taken as approval of this spec and of commit/PR/merge/TestFlight per phase, so implementation does not wait for a separate approval. Repo map from worker map-x (opencode, deepseek), verified: metro positions exist only per selected line; no CoreLocation; the only disk cache is the schedule pack; signing is manual with one profile for `cat.transport.app`, and the certificate is imported from a secret.
- L4 (2026-11-02) Design decisions:
  - no App Groups, because App Store Connect API-only signing cannot create group containers reliably, so the widget and watch fetch on their own;
  - no bus vehicles in global mode, to protect the TMB quota;
  - incident alerts are best-effort background refresh, because there is no backend.
- L5 (2026-11-02) T1 done (52fdd65). Metro stations are loaded per line, because `transit/estacions` lacks accessibility and the full line list. FGC station routes are derived geometrically (<=200 m). T2-T5 launched in parallel (qwen) with disjoint surfaces.
- L6 (2026-11-02) Phase A written: T2 f57e832, T3 0c91114, T4 6476f42, T5 9d4dd8d. Each worker stayed inside its surfaces (checked by git status before each commit). Next step: PR CI compile.
- L7 (2026-11-02) Phase A CI: first run had main-actor isolation errors (Explora views), fixed with `@MainActor` on 16 views plus `MapRegionTests`. The third run was cancelled with no error and passed on rerun (288 tests). PR #15 squash-merged as e4b640c, so TestFlight upload is pending. Phase B (T6 e674f1d, T7 c98beb3, T8 ea434b9, T9 7bda70a) is rebased on main in feat/roadmap-c, with one trivial StationDetailView doc/`@MainActor` conflict resolved by the parent. T12 6727939 got an independent verifier: PASS on all 6 items, no blockers. S15 ships dialog only (no snippet view), per the T7 contract.
