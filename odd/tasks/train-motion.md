# Train motion: one dot per train, andana-style live movement
Objective: trains move smoothly along the line, one marker per physical train, like andana.bcn.am/map.
Branch: feat/train-motion (to create) · Delivery: ask-on-risk · Test runner: XCTest (`Tests/TransportCatTests`), Linux via SwiftPM once T1 lands, otherwise macOS CI.
Status: approved by user 2026-10-30 ("sigue con el spec"). T2+T3 (engine-w, nan/deepseek-v4-flash) and T4 (camera-w, nan/qwen3.8-flash) written, uncompiled; CI on the PR is the first compile and test run. T1 skipped (needs user OK to install swift-bin). T5 (QA agent) replaced by the CI run plus the orchestrator's manual code review.

## Specs
- S1 Identity. One `TrainPosition` per train, identified by `(codi_servei, codi_trajecte)` on a line. Arrivals of the same train at several stations collapse to the one with the smallest seconds (the next station it will reach). `TrainPosition.id` is stable across polls: `"<line>-<codi_servei>-<codi_trajecte>"`, no seconds. Evidence: L1 yields 111 dots for 18 trains today.
- S2 Direction. Taken from `codi_via` (1 = toward the last station, 2 = toward the first), as andana does. Destination-name matching stays only as fallback when `codi_via` is absent. `Arrival` gains optional `trajectCode` and `via` with default `nil`, so the memberwise initializer keeps working. Evidence: 0 direction violations on L1/L3/L5 with `(servei, trajecte)` identity.
- S3 Progress. `progress = 1 - clamp((secToArrival - 45) / max(20, segDur - 45), 0, 0.95)`; train is dwelling at the station when `secToArrival <= 15`. Default speed 8.0 m/s (calibrated live; 9.2 was wrong). Evidence: 88% of trains sat clamped at progress 0 with the old formula.
- S4 Smooth motion. Between 20 s polls the marker advances every second by extrapolation along the polyline, capped at the segment end (train waits at the station). When a new poll changes the target, the displayed position catches up with a rate limit of 24 m per second (was 99-184 m median jumps) and never moves backwards against the travel direction; a new train snaps to its computed position, a gap above 1500 m snaps. The rate limit replaces andana's separate 2.2 s blend (assumption: same visual effect, one mechanism). The motion maths is a pure, deterministic value type (`TrainMotion`) so it is unit-testable; `LineState` drives it with a 1 s ticker task and publishes the result in `positions`.
- S8 Backward trains. A train travelling toward the first station is placed at `dist[prev] + (dist[next] - dist[prev]) * progress` (same formula as forward). Today the backward case interpolates from the next station toward the previous one, so a train about to arrive is drawn at the station it just left. The existing test `testDirectionBackwardTowardFirstStation` pins that wrong placement and is corrected as part of this spec (expected latitude about 41.35035 for progress 0.75).
- S5 Camera. On line change the map fits the selected line's stations (L5 currently loses stations off-screen).
- S6 Local loop. The engine, models and parsers compile and their tests run on this Linux machine with `swift test`, with no Xcode. Replay test: feed the captured live fixtures through parser + engine and assert S1/S2 (train count equals distinct `(servei, trajecte)`; no backwards movement between consecutive ticks).
- S7 No regression. Existing behaviour pinned by current tests (station projection, `Arrival.id`, parser outputs for existing fields) stays unchanged.

Out of scope: andana's L9/L10 pixel offsets, backend/server changes, new screens.

## Tasks
| ID | Specs | Route | Model / effort | Status | Commit |
|----|-------|-------|----------------|--------|--------|
| T1 | S6 | inline or delegated (Linux swift toolchain, SwiftPM `Package.swift` over Core/Engine+Models+TMB parsers) | deepseek, low | pending, needs user OK to install `swift-bin` (AUR) | - |
| T2 | S1 S2 S3 S7 | delegated, edit surfaces: `TransportCat/Core/Models/Arrival.swift`, `TransportCat/Core/TMB/TMBParsers.swift`, `TransportCat/Core/Engine/TrainPositionEngine.swift`, `Tests/TransportCatTests/**` | deepseek, medium | pending | - |
| T3 | S4 | delegated, edit surfaces: `TransportCat/Core/Engine/**` (new `TrainMotion.swift`), `TransportCat/Core/AppModel.swift`, `Tests/TransportCatTests/**` | deepseek, medium | pending, depends on T2 | - |
| T4 | S5 + wiring S4 in view | delegated, edit surface: `TransportCat/Features/Map/MapScreen.swift` | front-qwen, low | pending, depends on T3 | - |
| T5 | all | QA agent (deepseek, separate): runs full suite, checks each S# against raw evidence, adds one new test to the suite | deepseek, low | pending | - |

Slice estimate: about 350 authored lines, one PR.

## Log
- L1 (2026-10-29, user): "quiero que se vea movimiento en tiempo real de los metros por las lineas" and "ya se ven las lineas pero nada esta ajustado ni funciona como en andana https://andana.bcn.am/map los trenes van por donde quieren, va que lo puedes hacer mejor, orquestra bien"
- L2 (2026-10-30, user): "sí, prepáralo hay un iphone conectado por USB i estamos en omarchy, no se si se podra hacer alguna magia para testearlo localmente"
- L3 (2026-10-30): Evidence source is Engram #1317 (andana-recon + engine-sim2 reports; scratch files are gone). Engine is Foundation-only, so Linux SwiftPM testing looks feasible (to confirm in T1). `idevice_id -l` sees the iPhone (UDID 00008120-00167D1014BB401E); `swift` and `xcodebuild` are not installed.
- L4 (2026-10-30, user): "una vez hecho el spec delega la implementacion en pi con modelos del provider de NaN" -> implementation delegated to pi workers through hc (engine-w t12, camera-w t13). Reports: engine-w and camera-w scratchpad reports; deviations accepted: `import Observation` in AppModel.swift, `TrainPosition.moved(toRouteDistance:position:)` helper, replay fixtures of stations-L1 and imetro-L1 do not overlap (exact assertion is 0, a synthetic two-station replay covers S1/S2), snap threshold not unit-tested.
- L5 (2026-10-30, orchestrator review): found a defect outside the spec. `LineState.pollArrivals` kept the previous arrivals of stations missing from a response, so with the S1 collapse a stale low countdown would pin a train to a station it had already passed; and a failed poll re-anchored the markers to old data. Fix: the response replaces `arrivalsByStop` (it covers every station of the line) and a failed poll returns without recomputing. Not covered by a unit test (needs a LineState harness); verify on device.
