# Trajectes: saved trips pinned and tracked on the map

Branch `feat/trips` (worktree `CatTrans.wt/trips`). A trip (e.g. L1 + S1/S2 to Sant Cugat) is picked from the planner once, lives in a pill on the maps next to location and settings, and when active pins its lines on the global map with live per-leg tracking.
Design: canvas https://claude.ai/artifact/WuF4CJtKvAB7QKBcwo9isZ (artboards 1-5 + Spec). Workers: dsh headless on NaN flash models in herdr panes; orchestrator builds, tests and captures on the Mac.

## Specs

- S1 (user, 2026-11-19): "vamos a rematar el proyecto con el "explora" es poco dinamico, si, por ejemplo, quiero ir a St cugat quiero seleccionar la ruta que me dica (L1 + S2 fgc) i que me lleva al mapa, que sea como un pill de viaje planificado o viajes habituales o favoritos  junto a los de localizacion i settings, que quede las lineas que voy a cojer fijas en el mapa con el seguimiento necesario de horarios, tiempos de espera, todo lo que podamos aportar a un usuario "nrormal""
- S2 (user, 2026-11-19): "Piensalo un poco arranca un par de subagentes con DSH i GLM 5.3 (no el flash)  para hacer un brainstorm prepara un spec de como gestionar esto i presentamelo en un mockup"
- S3 (user, 2026-11-19): "empieza el desarrollo, me parece perfecto, aqui si, usa los modelos flash, testea todo lo necesario en el mac i cuando lo tengas envia al testflight, todo esto se tendran que cojer capturas para la web i el ASC es una feature brutal"
- S4 (approved mockup/spec, summarized): habitual / saved+recent trips, one active trip at a time; saved as legs (operator, line, from/to station ids, headsign, walk seconds), never frozen times; pill on every map; global map pins only the trip's lines and dims the rest; per-leg card with phases Esperant / A bord / Transbord / Arribat, live departures where the data exists, honest wording where it does not ("segons horari", FGC "a l'andana / a N parades / en hora", never an invented time); trip-line alerts in card and capsule with "Torna a planificar"; Explora section "Els teus trajectes"; planner detail actions "Segueix-lo al mapa", "Fes-lo habitual", "Desa".

## Tasks

| ID | What | Specs | Route | Status |
|----|------|-------|-------|--------|
| T0 | Verify planner coverage (B1) with a real call | S4 | inline (Mac) | done: multimodal, see L2 |
| T1 | Core: planner stop ids, SavedTrip/SavedTripLeg, TripsStore, TripTiming, Itinerary→SavedTrip, tests | S4 | dsh deepseek-v4-flash | done: 904 tests green on the Mac (7 wrong test expectations fixed inline) |
| T2 | Core: TripLiveState (per-leg live status from metro/bus/FGC/Rodalies sources + alerts + phase), tests | S1 S4 | dsh deepseek-v4-flash | done: 4 compile errors + 3 real bugs fixed inline, 23 tests green |
| T3 | UI: trip pill on every map, trips sheet, active-trip card + capsule, global map pinning | S1 S4 | dsh glm5.3-flash | done: compile errors fixed inline (1578daf) |
| T4 | UI: planner detail actions, Explora "Els teus trajectes" | S1 S4 | dsh glm5.3-flash | done: builds; simulator check in T6 |
| T5 | Localization ca/es/en for the new strings | S4 | dsh flash | done: 50 keys es/en, catalog script fix |
| T6 | Mac: build, full tests, simulator tour of the whole flow, fixes | S3 | inline + workers | done: 0eab25b, 757d4a0; 931 tests green; ca captures OK |
| T7 | Screenshots: web chapter (ca/es/en) + ASC captures/panorama panel | S3 | inline + worker | partial: sheet + planner captures in src2; map captures, panorama slide and web chapter blocked on the Mac's TMB keys |
| T8 | Ship: PR, CI, merge, TestFlight | S3 | inline | in progress |

## Log

- L1: original request = S1; brainstorm (S2) by two dsh glm5.3 workers (UX + tech), spec and mockup approved with S3.
- L2: decision (T0, 2026-11-19): the TMB planner is multimodal. Rocafort → Sant Cugat returned SUBWAY L1/L3 (`agencyName` TMB, `stopId` `3:1.123`, `stopCode` 123 = CODI_ESTACIO), RAIL S1/S2 (`agencyName` FGC, `stopId` `2:GR1` = FGC station code `GR` + platform digit, `routeShortName` S1); Sants → Aeroport returned RAIL R2N (`agencyName` Renfe Cercanias, `stopId` `4:71801` = Rodalies GTFS stop_id) and buses of other operators (Monbus A1, Avanza). So trips are created from the planner; the "Crea'l per trams" manual builder from the mockup is dropped (YAGNI).
- L3: discovery: FGC has no per-station ETA or timetable in the app, only live train positions (`FGCTrain.nextStopCodes`, `stoppedAtStopCode`, `isOnTime`). Pl. Catalunya is the S1/S2 terminus. FGC legs show live position wording only; an FGC GTFS pack is a later improvement.
- L4: T1 worker wrote the code in ~7 min, then spent its time building a Linux harness to run XCTest; it was stopped and verified on the Mac instead. Workers now report progress to a log file (headless panes show nothing until exit) and are told not to build Linux harnesses.
- L5: T2 review on the Mac found real bugs the worker's tests encoded: "després 7 min i 11 min min"; an invented alias rule that made line "11" match "1" (L1 alerts on L11 trips); FGC legs counted only the planner's line. Decision: an FGC leg counts every train that stops at the boarding station and then at the destination (Gràcia → Sant Cugat: S1 and S2); aliases go through `FGCNetwork.baseLineCode(for:)`; line codes otherwise match exactly. The FGC feed lists all remaining stops and omits the station a stopped train is at (checked on `fgc-positions.json`).
- L6: alert coverage: metro and TMB bus yes; FGC none (no alert feed in the app); Rodalies none today (model exists, no poller). Cards show no alert for those legs rather than a fake "sense incidències".
- L7: T6 (2026-11-19): two flash workers spent ~3 h on a "trips sheet draws only its first row" bug that was not one: the probe's saved trip was never stored (Rocafort → Pl. Catalunya's first answer is walk-only) and the medium detent only shows what fits. Their experiments made GlobalMapScreen take 3+ min to type-check (normal build ~17 s). Reverted; kept the real fixes: start(trip:) follows the stored trip by signature, live phase only while waiting, badge sizing. DEBUG probes: -tripProbe seed|plan, -tripsSheet open|large, -plannerProbe open.
- L8: T7 (2026-11-19): the global map centred the route under the trip card; fixed by giving the map the card's height as bottom safe area (unit-tested camera rect; on-screen check pending). The Mac lost its TMB keys (a worker's build with placeholder keys; tc.sh inherited keys from the last built app): tc.sh now picks a build with real keys and refuses otherwise. Captures blocked until the keys are restored on the Mac.
