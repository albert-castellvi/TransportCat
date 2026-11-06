# Redesign v2 — fullscreen map, unified markers, Parades tab, network motif, nearby
Objective: ship the approved v2–v6 redesign (mockups in `docs/design/redesign-v2/*.dc.html`, the authoritative visual spec) on iOS 26.
Branch: `feat/redesign-v2` (from main d48cfa1). Delivery: ask-on-risk; work-unit commits on the branch, PRs decided by the user. Test runner: XcodeGen + `xcodebuild test` on the CI simulator (`.github/workflows/ci.yml`); locally only `swiftc -parse` + `git diff --check` (Linux, no SDK). CI is the only type-checker.

## Specs

- S1 Fullscreen map, no top bar. User (L2): "haz un rediseño de la pantalla del mapa para no tener esa barra negra encima, imaginatelo como un fullscreen del mapa i pills para las diferentes opciones, IOS 26/27 style". The four map screens lose their top header (ModeSelector + chips rows + navigation title); the map fills the screen under the status bar. Mockups `V2Main`, `V2Menu`, `V2Tot`.
- S2 Status capsule, top-left over the map (and over Parades/Avisos): one glass capsule that merges `FreshnessChip` and the offline banner. It reuses `Freshness` levels and wording unchanged (tested in `FreshnessTests`) and `ConnectivityMonitor.isOnline`; when offline it shows a wifi-off icon and "Sense connexió" plus the existing theoretical/saved-data wording. One source of truth, no second freshness computation.
- S3 Location button, top-right of the map (glass circle, 44 pt). It keeps today's centre-on-user behaviour; in S13 it also opens the nearby sheet.
- S4 Bottom accessory (`tabViewBottomAccessory`), shared by Mapa and Parades:
  - A mode `Menu` button labelled with the current mode ("Metro" / "Bus" / "FGC" / "Tot") plus an up/down chevron. It reads and writes the existing `appMode` storage and `AppMode` raw values; the menu lists the four modes with a check on the current one.
  - A context control per mode:
    - Metro: a line chip (badge + termini). It opens the existing metro line picker as a sheet and shows an amber warning icon when the line has a service alert.
    - Bus: a line chip that opens `BusLinePickerSheet`, plus a direction swap button.
    - FGC: a line chip that opens the FGC line picker.
    - Tot: Metro/Bus/FGC toggles over `GlobalOperatorSelection`.
  - It uses the same selection keys as today (`metroSelectedLine`, `busSelectedLine` — owned by `BusCatalogStore`, never renamed — `fgcSelectedLine`, the global operators key). No new selection state.
- S5 Tab bar: Mapa / Parades / Avisos, plus the search tab (`Tab(role: .search)`) hosting today's Explora content (search, favorites, planner entry). The middle tab is renamed "Parades" everywhere it shows today as "Línies" or "Xarxa" (tab label, navigation titles). User (L5): "el menu de lineas que quiza podemos cambiarle incluso el nombre (piensalo)"; the rename was approved in L6.
- S6 Unified vehicle marker (mockup `V3Markers`) for metro, FGC, bus and Tot:
  - A solid circle in the line colour with a white ring and an upright glyph (train, or bus). A heading wedge rotates around the circle from the existing heading values; Tot shows the line code instead of the glyph.
  - The ring is dashed when the position is a timetable estimate (metro `isTheoretical`).
  - No line-name label on each vehicle. The selected vehicle gets a halo plus its destination label.
  - Tapping a vehicle opens a glass card above the accessory: destination, next stop (plus ETA where the data exists), and whether the position is live or estimated.
  - Hollow station dots; metro–metro interchanges drawn as white capsules.
  - Clusters are out of scope (D3).
- S7 Incidents on the map:
  - Service alerts (`AlertSeverity.service`): the affected run is dotted in the line's own colour (never repainted in another colour), with ONE amber badge (warning icon + line code) per run, for metro and bus.
  - Facility alerts (`.facility`): a small grey lift/escalator icon on the station, in single-line modes only, never in Tot.
  - Tot: one badge per affected line, grouped into "N línies" when the badges overlap (D6).
  - FGC: line-level only (D2).
  - Tapping a badge opens a glass card with the alert text, its time and source, and "Veure a Avisos".
  - Mockups `V3Metro`, `V3Bus`, `V3Tot`.
- S8 Parades, metro (mockup `V4Metro`):
  - A sticky direction header names each terminus ONCE; each station row shows plain tabular times per direction: "ara" in green when imminent, "—" when there is no service.
  - The rail is in the line colour, dotted on affected runs, with the S6 vehicle markers on it.
  - Metro interchange badges; "Ets aquí · <distance>" on the nearest station; facility alerts inline in grey.
  - One service card per affected run at the top.
  - Removed: the duplicated destination pills on every station and the per-station "Trens pegats" label.
  - Alert counts come from one source, so they can no longer contradict each other (today "2 incidències" vs "6 incidències a L2").
- S9 Parades, bus (mockup `V4Bus`): one direction at a time (swap in the accessory); each stop shows its name, its street, and the next two buses; "Sense dada" when no arrival is known. It must stay inside `BusLineState.pollPlan` (no extra iBus calls).
- S10 Parades, FGC and Tot:
  - FGC (D1): stations on the rail with the trains and their destination; no minute columns, because there is no FGC ETA source.
  - Tot (mockup `V4Tot`): "A prop teu" (nearest stops with the next arrivals per line, sorted by walking time) plus "Estat de les línies" (a grid of line badges with an amber dot when the line is affected). This replaces today's "L1 · L1" list.
  - The nearby list is one reusable component (also used by S13).
- S11 Network motif from the app icon (mockups `V5*`): one `NetworkArt` view (octilinear lines, white stations, interchange rings).
  - Used as header art on Parades: fades out before the content, about 50 % opacity.
  - Used for the Avisos empty state "Tot funciona", with the facility-alert count row kept.
  - Used for the loading state, replacing "Carregant…": the lines draw in; static under Reduce Motion.
  - Never a full-screen pattern behind lists.
- S12 Deployment target iOS 26.0 for the app and the widget extension (user decision, L7: "Subir a iOS 26").
- S13 Nearby sheet (mockup `V6Nearby`): the map's location button centres on the user and opens an "A prop teu" sheet built from the S10 component; the button is filled while the sheet is open. User (L8): "\"a prop teu\" quiza deberia ser un menu aparte no? como lo ves, algun tipo de acceso directo".
- S14 Home-screen quick actions (mockup `V6QuickAction`): "A prop teu", the last line viewed, "Avisos", "Cercar una parada". Each routes through `AppRouter`.
- S15 Preserve (non-regression):
  - The ZStack + `RetainedMode` contract in `RootView`, and poll ownership (`.task(id: mode)`, `FGCNetworkState.shared` started only there, the process-wide `GlobalNetworkState`).
  - `PerfTelemetry` / `FrameMonitor` / `PerfTrace` wiring, the `GlobalZoom` hysteresis, and Equatable markers / derived `@State` overlays off the 10 Hz path.
  - Catalan accessibility labels and 44 pt targets.
  - `AppRouter.open` and its focus handling.
  - All existing tests stay green (update them, never delete them, when copy changes).

## Tasks

| ID | Specs | Route | Status | Commit |
|----|-------|-------|--------|--------|
| T0 | S12 | inline (parent), Risk item 5 | done: CI run 42209911222 built and passed all simulator tests on iOS 26 | 2ae59a9 |
| T1 | S1–S5 | delegated pane `chrome` (glm5.3-flash, thinking high = max), wave 1 | committed; CI run 42213124800 pending. Parent review: RootView, BottomAccessory and every dependency verified at their definitions; added an explicit `.environmentObject(app)` on the accessory. Known limitation: on a first launch the termini and the bus swap stay hidden until the topology cache exists | 1479d0c |
| T2 | S8–S10 | delegated pane `parades` (glm5.3-flash, thinking high = max), wave 1 | committed locally; push waits for T1 CI green. Follow-up F1 (T7): metro interchange badges read `GlobalNetworkState.shared.lineStates`, which is empty until Tot has run, so in Metro mode they are usually missing; switch to the places catalog (`Place.lineCodes`, as MapScreen does) | 497ce65 |
| T3 | S11 (NetworkArt, Avisos empty, loading) | delegated pane `motif` (glm5.3-flash, thinking high = max), wave 1 | done: CI run 42211895995 compiled it and passed all tests, including NetworkArtTests. Review fixes: the copy is metro-only ("Cap incidència de servei al metro."), the facility row is generic ("N instal·lacions fora de servei"), explicit @ViewBuilder | 8c05e06 |
| T4a | S6–S7 metro + bus maps | delegated pane `markers-mb` (GLM 5.3, high), wave 2 | done (parent review: rules, tests, inits) | T4a commit |
| T4b | S6–S7 FGC + Tot maps (D6 grouping helper) | delegated pane `markers-ft` (GLM 5.3, high), wave 2 | done (CI 42224359028: 531 tests, 0 failures) | T4b commit |
| T5 | S13–S14 | delegated pane `nearby` (GLM 5.3, high), wave 2 | done; FGCMapScreen init fix 01b59ea | T5 commit |
| T6 | S11 header art on Parades + fix F1 | inline (parent) | done (CI 42221077017: 498 tests, 0 failures) | T6 commit |
| W1 | wave 1 green | CI run 42218462529: 497 tests, 0 failures, iOS 26 | done | 1479d0c..(test fix) |
| T7 | S15 + cleanup | parent + independent verifier | done: 'Més detalls' / 'Veure a la línia' restore follow and the line jump; one interchange rule; dead views removed; temporary flag removed; verifier 0 blockers; CI 42226854647 526 tests, 0 failures | T7 commits |

Route evidence: the writer trigger is (a) parallelism. T1/T2/T3 have disjoint edit surfaces, and each is several files and well over 100 lines. T4 and T5 share the map files with T1, so they wait for wave 2.

## Log

- L1 2026-11-06 (original request, verbatim): "mientras se hace el testflight, haz un rediseño de la pantalla del mapa para no tener esa barra negra encima, imaginatelo como un fullscreen del mapa i pills para las diferentes opciones, IOS 26/27 style, prepara un mockup"
- L2 2026-11-06 "dale un pensamiento mas, UX/UI" → v2 (controls at the bottom). L3 "me gusta mucho mas, ahora rediseña como se ven las incidencias en las lineas, los vehiculos (metros, trenes FGC, busses, .....)" → v3. L4 "me gusta, mucho mas limpio sin duda" (v3 approved).
- L5 2026-11-06 "el menu de lineas que quiza podemos cambiarle incluso el nombre (piensalo) prepara el rediseño" → v4 "Parades". L6 "se podria hacer un desiño del fondo tipo lineas de metro, como el propio icono de la app" → v5.
- L7 2026-11-06 deployment target question → "Subir a iOS 26 (Recomendado)".
- L8 2026-11-06 "dale al merge si, \"a prop teu\" quiza deberia ser un menu aparte no? como lo ves, algun tipo de acceso directo, piensa tu en la UX no soy para nada exporto en frontend i UX" → v6 (nearby sheet + quick actions). PR #22 merged d48cfa1, TestFlight 260087ae-8b1f-4649-b59c-10a844cc1a0c.
- L9 2026-11-06 "ME PUTO ENCANTA A POR ELLO lanza los agentes de NaN a trabajar con el MAX de thiking, no quiero errores tontos en esto" → implementation authorized.
- L10 Read-only audit (GLM 5.3, report `scratchpad/poll/reports/redesign-codeball-opener.md`, Engram #1415). Data gaps: no FGC per-station ETA, no FGC runs, no clustering, unproven cross-operator interchange identity, Tot has no run model. Spot check found one wrong claim ("no user location overlay": `GlobalMapScreen` does draw `UserAnnotation` and `MapUserLocationButton`), so writers must re-verify every claim against the code.
- L11 UX decisions (user delegated UX in L8):
  - D1 FGC Parades shows no minutes.
  - D2 FGC alerts are line-level only (no dotted runs).
  - D3 Vehicle clusters are deferred.
  - D4 Interchange capsules are metro–metro only for now.
  - D5 Buses keep a solid ring. All bus positions are arrival-based estimates, which the card says; the dashed ring stays reserved for metro timetable positions.
  - D6 In Tot, one badge per affected line at its first affected station, grouped when the badges overlap.
- L12 T0 committed (2ae59a9) with the docs commit (c906e9b); branch pushed, CI run 42209911222 dispatched.
- L13 Model choice: qwen3.8-flash ignores the thinking level (the pane shows "auto" with both `--thinking max` and `:max`). GLM 5.3 flash honours it, capped at "high". Because the user asked for "el MAX de thiking", the writers T1–T3 run on GLM 5.3 at high, overriding the usual UI→qwen rule. Briefs: scratchpad `redesign-common.md`, `task-t1-chrome.md`, `task-t2-parades.md`, `task-t3-motif.md`. Cross-unit contracts: the `FreshnessChip` initializers stay unchanged; `BusDirectionSelection` (key "busDirectionID", `resolve`, `swapped`) is created by T1 and consumed by T2; `MapLoadingPlaceholder` keeps its initializers; `VehicleMarkerView` is created by T2 and reused by T4; `NearbyStopsList` is created by T2 and reused by T5.
- L14 2026-11-06 user: "peto el CI" / "por favor revisa bien y que no vuelva a fallar". Wave 1 needed seven CI rounds:
  - Writer mistakes: a duplicated member, an invented API name, a wrong argument plus a missing await, `if let` on a non-optional, a mixed-type ternary, a stray token, test argument order. Wrong test expectations found by hand: `Place.id` format, "5 min", walking-minute rounding, a floating-point tie.
  - Parent mistake: `IPHONEOS_DEPLOYMENT_TARGET: "17.0"` at project.yml:21 overrode the 26.0 deploymentTarget (fixed c92edd6).
  - Countermeasures:
    - temporary `OTHER_SWIFT_FLAGS -continue-building-after-errors` (remove in T7);
    - the parent reads every new test against the real models before pushing;
    - a mandatory item-9 checklist in the writer briefs;
    - contracts written as real compiled code before parallel writers start (`MapOverlays.swift`, `AppRouter.isNearbyPresented`).
  - Result: CI run 42218462529 green, 497 tests and 0 failures.
- L15 Wave 2 plan: T4a (metro + bus maps), T4b (FGC + Tot maps), T5 (nearby sheet + quick actions), in parallel with disjoint surfaces. `BusMarker` stays until T7 (T4b's files still use it). Briefs: scratchpad `task-t4a-markers-metro-bus.md`, `task-t4b-markers-fgc-tot.md`, `task-t5-nearby.md`.
- L16 2026-11-06 user: "en cuanto este lanza la segunda oleada, y en cuanto este todo, lanza a testfligh". Wave 2 ran in parallel.
  - Parent review fixes: the FGCMapScreen explicit init hid onLocate (01b59ea); the cards lost 'follow' and Tot's line jump (restored in T7).
  - Independent verifier (pane verify-feature, report in scratchpad verify-feature-report.md): S1–S15 MET, 0 blockers, 0 regressions vs d48cfa1.
  - Advisories: the timeline regularity tags were dropped (spec S8); on a first launch the accessory shows no termini until the topology cache exists.
  - Final CI 42226854647: 526 tests, 0 failures, without the temporary flag. Next: PR to main, squash merge, TestFlight.
