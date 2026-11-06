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
| T0 | S12 | inline (parent), Risk item 5 | in progress | — |
| T1 | S1–S5 | delegated `chrome` (qwen3.8-flash, thinking max), wave 1 | pending | — |
| T2 | S8–S10 | delegated `parades` (qwen3.8-flash, thinking max), wave 1 | pending | — |
| T3 | S11 (NetworkArt, Avisos empty, loading) | delegated `motif` (qwen3.8-flash, thinking max), wave 1 | pending | — |
| T4 | S6–S7 | delegated, wave 2 (after T1: same map files) | pending | — |
| T5 | S13–S14 | delegated, wave 2 (after T1 + T2) | pending | — |
| T6 | S11 header art on Parades | inline (parent), after T2 + T3 | pending | — |
| T7 | S15 + cleanup (dead `AlertBanner`, unused `ModeSelector`/pickers, docs, help) + final verify | parent + independent verifier | pending | — |

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
- L12 Next: T0 inline commit, then launch T1/T2/T3 in parallel herdr panes (gentle-shell, NaN, `--thinking max`).
