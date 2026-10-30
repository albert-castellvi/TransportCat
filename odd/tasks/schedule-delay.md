# Schedule pack in CI, regularity, bus delay and theoretical L9/L10 trains
Objective: use TMB's static GTFS (precomputed in CI into a compact pack bundled in the app, nothing heavy parsed on the phone) to (a) draw theoretical trains on lines without a live feed (L9N, L9S, L10N, L10S, FM), (b) flag service gaps and bunching on metro and bus lines, (c) estimate bus delay against the timetable, always labelled as theoretical or estimated.
Branch: feat/schedule (from main) · Delivery: ask-on-risk · Test runner: XCTest; Foundation-only code runs locally with Linux `swift test`; the Python builder with `python3 -m unittest`.
Status: approved by user 2026-10-30 ("dale, pero tiene que ser lo mas agil posible, opcion de precalcular en CI ... AGIL limpia"). Order refinement: FGC delay waits for the FGC mode itself (separate phase).

## Verified facts (2026-10-30)
- `GET https://api.tmb.cat/v1/static/datasets/gtfs.zip?app_id=..&app_key=..` (same credentials as the rest): 8.2 MB, 0.9 s. Members: routes (118: 10 metro `route_type` 1 incl. L9N/L9S/L10N/L10S, 1 funicular type 7, 107 bus type 3), trips (`route_id,service_id,trip_id,trip_headsign,direction_id,shape_id,wheelchair_accessible`; L1 1996 trips, L9N 1243), stop_times (58 MB: `trip_id,arrival_time,departure_time,stop_id,stop_sequence`; times may exceed 24:00:00), calendar (weekday flags + `start_date`/`end_date`, valid until 2027-03-27), calendar_dates (exceptions, type 1 add / 2 remove), frequencies (4 rows `trip_id,start_time,end_time,headway_secs`), stops, shapes, transfers, pathways.
- Ids: metro route_id `1.<line code>.1` (L1 `1.1.1`, L9N `1.94.1`), stop_id `1.<codi_estacio>` (`1.111` = Hospital de Bellvitge); the numeric part after the last dot is the stop code used by iMetro and by `Station.code`. Bus: verify the same pattern against live data (H12 = line code 212, stop 7 = Pl Universitat).
- Experiment: live L1 ETAs vs nearest scheduled arrival at the same station: median |delta| 54.5 s, p90 102 s with a 180-219 s headway, so per-train punctuality is NOT identifiable on high-frequency metro; use headway regularity there.

## Pack format v1 (contract between T1 and T2)
Output folder (default `TransportCat/Resources/Schedule/`): `index.json` and one file per route.
```
index.json: {"v":1,"generatedAt":"<ISO8601>","feedStart":"YYYYMMDD","feedEnd":"YYYYMMDD","timezone":"Europe/Madrid",
             "lines":[{"mode":"metro"|"bus"|"funicular","code":<Int>,"name":"L9N","file":"metro-94.json"}, ...]}
<mode>-<code>.json: {"v":1,"mode":"metro","code":94,"name":"L9N",
  "dates":{"20261030":0,"20261031":1,...},            // every date of the feed range -> day type index (dates with no service omitted)
  "directions":[{"id":0,"headsign":"...",
     "patterns":[{"stops":[<stopCode>,...],"arr":[<sec from trip start>,...],"dep":[<sec from trip start>,...]}],
     "dayTypes":[ [[<startSec>,<patternIndex>], ...sorted by startSec ] , ... ]   // one list per day type index
  }]}
```
`startSec` = departure-time-of-first-stop in seconds from service-day midnight (may exceed 86400). `arr`/`dep` are offsets from the first stop's arrival (first `arr` is 0). Day types are the distinct sets of active `service_id`s (calendar + calendar_dates applied per date); frequencies rows are expanded into explicit starts. Patterns are de-duplicated per direction. Stop codes are Ints (numeric part after the last dot of `stop_id`). Output JSON is compact (no spaces) and deterministic (sorted keys/lists). The whole pack stays under 15 MB; the report prints per-file and total sizes.

## Specs
- S1 Builder. `scripts/build-schedule-pack.py` (Python 3 standard library only): inputs `--out <dir>` and either `--zip <path>` or download using env `TMB_APP_ID` and `TMB_APP_KEY` (never printed, never in argv of logs); streams `stop_times.txt` once; writes the pack of the format above; exits non-zero with a clear message on any failure (download, missing member, no routes). `scripts/test_build_schedule_pack.py` (unittest) covers it with a tiny synthetic GTFS built in memory (calendar plus an exception date, an after-midnight trip, a frequencies row, two directions, a shared pattern de-duplicated) asserting the exact output. CI: in the signed-archive job of `.github/workflows/ci.yml`, before `xcodegen generate`, a step runs the builder with the job's TMB credentials into `TransportCat/Resources/Schedule/`; the test job runs `python3 -m unittest` for the script tests only. `project.yml` bundles `TransportCat/Resources/Schedule` as a resource folder (folder reference, so a missing `.gitkeep`-only folder works); generated files are git-ignored except `.gitkeep`. Test fixtures: a real mini pack (index plus `metro-94.json`, `bus-212.json` produced by the builder from the real feed, restricted to the next 7 dates to stay small) under `Tests/TransportCatTests/Fixtures/schedule/`.
- S2 Core (Foundation only, `TransportCat/Core/Schedule/`). `SchedulePack`, `ScheduleLine`, `ScheduleDirection`, `SchedulePattern`, `ScheduledRun` as in Contracts: lazy per-line loading and caching, service-day lookup in the pack's timezone (a trip starting after midnight of the previous service day is included when asked about the next day: query the day and the previous day), O(log n) arrival lookups per stop and direction (index built once per line/direction/day type).
- S3 Regularity. `Regularity.assess(live:scheduled:now:)` per Contracts. Scheduled headway = median gap of scheduled arrivals within [now - 10 min, now + 30 min]; observed gaps = consecutive live arrivals; `.gap` when an observed gap >= 1.8 x headway and >= 240 s; `.bunched` when an observed gap <= 0.35 x headway and headway >= 150 s; `.regular` otherwise; `.unknown` with fewer than two live arrivals or no scheduled headway.
- S4 Bus delay. `BusDelay.estimate(...)` per Contracts: candidate runs = runs of the line and direction that contain at least one observed stop; for each, offsets = observed ETA - scheduled arrival at each observed stop; the run with the smallest |mean offset| whose offsets spread (max - min) is under 90 s wins; nil if none; confidence `.high` when >= 3 observed stops, spread < 45 s and scheduled headway >= 4 x |delay|, `.medium` when headway >= 2.5 x |delay|, else `.low`; result nil when |mean| > headway / 2 (ambiguous). Shown only as "estimat".
- S5 Theoretical trains. `TheoreticalFleet.positions(line:stations:engine:now:calendar:)` returns one `TrainPosition` per scheduled run in progress (between its first departure and its last arrival) at `now`: segment found from the pattern times, position interpolated linearly in time between the route distances of the stations (`TrainPositionEngine.stationRouteDistances`, new read-only accessor), dwell at a stop when `now` is between its arrival and departure; direction forward when the pattern's first stop has a lower station index than its last; id `"T<directionID>-<startSec>"`; `TrainPosition.isTheoretical` (new field with default false) true. Stops of the pattern missing from `stations` make the run skipped.
- S6 Wiring (T2). `AppModel` exposes `let schedule: SchedulePack?` (bundled pack, nil when absent: every feature degrades silently). `LineState`: when the poll says the feed is empty (`isFeedEmpty`) and the schedule has the line, `positions` come from `TheoreticalFleet` evaluated at every 10 Hz tick; new `var isTheoretical: Bool`; `func regularity(stationCode: Int, via: Int, now: Date) -> RegularityReport?` (via 1 = toward the last station; maps to the scheduled direction by pattern order). `BusLineState`: `func delay(forBus id: Int) -> DelayEstimate?` (observations accumulated from the last poll: every polled stop where the bus has an ETA) and `func regularity(stopCode: Int, directionID: Int, now: Date) -> RegularityReport?`.
- S7 UI (T3). (a) Theoretical trains: markers drawn at 70 % opacity; `FreshnessChip(lineState:)` shows a blue dot and "Horari teòric" when `isTheoretical`; `NoRealtimeDataCard` (both styles) says "Sense dades en temps real" + "Es mostra l'horari teòric." when a line is theoretical and keeps the current text when the schedule is missing. (b) Xarxa rows (metro `DiagramScreen` and bus `BusDiagramScreen`): a small tag under the station name when regularity is `.gap` ("Buit de N min", orange) or `.bunched` ("Trens pegats" / "Busos pegats", orange), nothing otherwise; metro uses `via` 1 and 2 and shows the worse one. (c) Bus stop sheet: for arrivals of buses with a delay estimate a second info line "En hora" (|delay| < 60 s), "+N min tard · estimat" or "N min d'avanç · estimat" (confidence `.low` is not shown); `BusStopSheet` gets an optional `delays: [Int: DelayEstimate] = [:]` parameter and `BusMapScreen`/`BusDiagramScreen` pass `state.delay(forBus:)` values for the stop's buses.
- S8 No regression and agility. The pack is loaded off the main thread, never blocks a screen, and a missing pack changes nothing; no new dependency; existing tests keep passing.

## Contracts (T2 owns the Swift; T1 the pack; T3 consumes)
```swift
// Core/Schedule/SchedulePack.swift (T2)
enum ScheduleMode: String { case metro, bus, funicular }
struct SchedulePattern: Hashable { let stops: [Int]; let arrivals: [Int]; let departures: [Int] }
struct ScheduleDirection { let id: Int; let headsign: String; let patterns: [SchedulePattern]; let dayTypes: [[(start: Int, pattern: Int)]] }
struct ScheduledRun { let directionID: Int; let headsign: String; let start: Date; let pattern: SchedulePattern; var end: Date { get }; func arrival(at stopCode: Int) -> Date? }
struct ScheduleLine { let mode: ScheduleMode; let code: Int; let name: String; let directions: [ScheduleDirection]
  func runs(on day: Date, directionID: Int?) -> [ScheduledRun]   // service day of `day` plus the previous service day's after-midnight runs
  func arrivals(at stopCode: Int, directionID: Int, on day: Date) -> [Date] /* sorted */ }
final class SchedulePack { static func bundled() -> SchedulePack?; init(index: Data, loadFile: @escaping (String) -> Data?) throws; var timeZone: TimeZone; func line(mode: ScheduleMode, code: Int) -> ScheduleLine? }
// Core/Schedule/Regularity.swift, BusDelay.swift, TheoreticalFleet.swift (T2)
struct RegularityReport: Equatable { enum Status { case regular, gap, bunched, unknown }; let status: Status; let scheduledHeadway: TimeInterval?; let observedHeadway: TimeInterval?; let longestGap: TimeInterval? }
enum Regularity { static func assess(live: [Date], scheduled: [Date], now: Date) -> RegularityReport }
struct DelayEstimate: Equatable { enum Confidence { case high, medium, low }; let seconds: Int; let confidence: Confidence; let scheduledArrival: Date }
enum BusDelay { static func estimate(observations: [(stopCode: Int, eta: Date)], line: ScheduleLine, directionID: Int, now: Date) -> DelayEstimate? }
enum TheoreticalFleet { static func positions(line: ScheduleLine, stations: [Station], engine: TrainPositionEngine, now: Date) -> [TrainPosition] }
// TrainPosition (T2): add `var isTheoretical: Bool = false` last. TrainPositionEngine (T2): `var stationRouteDistances: [Double]`.
// AppModel (T2): `let schedule: SchedulePack?`. LineState (T2): `isTheoretical`, `regularity(stationCode:via:now:)`. BusLineState (T2): `delay(forBus:)`, `regularity(stopCode:directionID:now:)`.
```

## Tasks
| ID | Specs | Route | Model / effort | Status | Commit |
|----|-------|-------|----------------|--------|--------|
| T1 | S1 | delegated: scripts/build-schedule-pack.py, scripts/test_build_schedule_pack.py, .github/workflows/ci.yml (the two steps only), project.yml (resource folder only), .gitignore, TransportCat/Resources/Schedule/.gitkeep, Tests/TransportCatTests/Fixtures/schedule/** | nan/deepseek-v4-flash, medium | pending | - |
| T2 | S2 S3 S4 S5 S6 | delegated: Core/Schedule/*.swift, TrainPositionEngine.swift, AppModel.swift, BusLineState.swift, tests ScheduleTests/RegularityTests/BusDelayTests/TheoreticalFleetTests | nan/deepseek-v4-flash, medium | pending | - |
| T3 | S7 | delegated: FreshnessChip.swift, MapScreen.swift (theoretical opacity only), DiagramScreen.swift, BusDiagramScreen.swift, BusStopSheet.swift, BusMapScreen.swift (pass delays only) | nan/qwen3.8-flash, medium | pending | - |

Risk line: item 5 (CI workflow and bundled resources change delivery) for T1; independent verification = run the builder against the real feed locally and compare the pack with the fixtures, plus the PR's test job; the signed-archive step only runs on main, so the first main run is its real test.

## Log
- L1 (2026-10-30, user): "piensa en como se podria calcular los retrasos" then "dale, pero tiene que ser lo mas agil posible, opcion de precalcular en CI, repito tiene que ser AGIL limpia, que no te de un ictus por la lentitud"
- L2 (2026-10-30, orchestrator): findings behind the design: TMB `/horaris` has only first/last departure; bus `/horespas` gives text schedules per stop; the GTFS zip has everything including L9/L10 and metro stop_times; L1 experiment shows per-train delay is unidentifiable at 3-4 min headways; FGC has official `en_hora` and GTFS-RT trip updates (separate phase).
