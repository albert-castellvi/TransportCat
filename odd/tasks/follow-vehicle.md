# Follow a vehicle — chase camera, stop announcements, alight alarm, Live Activity
Objective: follow a metro, bus or FGC vehicle in an immersive "SimCity" view that announces stops and warns the rider where to get off (mockups `docs/design/follow-vehicle/V7*.dc.html`).
Branch: `feat/follow-vehicle` (from main ef79a3d). Delivery: one PR, squash merge, then TestFlight (user: "me encanta, a por ello y luego testflight"). Test runner: CI only (`xcodebuild test`, iOS 26 simulator); locally `swiftc -parse` + `git diff --check`.

## Specs

- S1 Start following from the existing "Seguir" toggles in the metro, bus and FGC vehicle sheets, from the router `.vehicle` focus, and from a new "Seguir" button on the map's vehicle glass card, next to "Més detalls". While following, the map screen is immersive: the tab bar and the bottom accessory are hidden, with the HUD at the top and the follow panel at the bottom. Tot is not followable (its "Veure a la línia" stays).
- S2 Chase camera (mockup `V7Follow`):
  - A tilted camera behind the vehicle (`MapCamera` with a pitch of about 60°, heading = the vehicle heading, distance of about 400 m) and `.standard(elevation: .realistic)`.
  - The style switches once at follow start and stop, never per tick.
  - "2D" falls back to today's north-up region centring.
  - A pan pauses the camera, not the session; the HUD then offers "Tornar al tren".
- S3 Route: the route ahead is highlighted in the line colour and the passed route is dimmed. The split is recomputed only when the next stop changes, never on the 10 Hz tick. Labels on the map mark the next 4 stops with their ETA (metro and bus) or only their name (FGC, D1); the alight stop is green with a flag.
- S4 HUD: "Seguint · cap a <terminus>" with the source ("En directe" / "Posició estimada"), a voice toggle, a stop button and the 2D/3D toggle. No speed and no exit side (D2).
- S5 Follow panel:
  - "Pròxima parada", the stop name and its countdown ("ara" / "<n> min" from `Arrival.countdownText`; FGC shows no minutes).
  - A strip with the last passed stop plus the next ones (5 in total) and the vehicle between them.
  - A row "Baixo a <stop>" that picks the alight stop from the stops still ahead, with "T'avisarem en arribar a <stop before>". Without a choice it reads "Tria on baixes".
- S6 Announcement: each time the next stop changes, show the card "Pròxima parada · <stop>" and, when voice is on, speak it in Catalan. The card adds the interchange ("Correspondència amb la L4") and the facility alert ("Ascensor fora de servei") when they exist. One announcement per stop.
- S7 Alight alarm: when the next stop becomes the chosen alight stop, show the green card "Baixa a la pròxima: <stop>" with its interchange, a success haptic, speech when voice is on, and "D'acord" to dismiss it.
- S8 Background:
  - A follow Live Activity (new `FollowActivityAttributes`) shows the next stop, its countdown via a system timer (metro and bus), the terminus and the progress to the alight stop. The Dynamic Island compact view reads "<stop> · <n>′".
  - Starting a follow ends any arrival Live Activity (D4).
  - A local notification "Baixa a la pròxima: <stop>" is scheduled for the predicted time and rescheduled on every update. It is a regular notification, not time-sensitive (D3). FGC schedules none, because it has no ETA.
- S9 Stop: the HUD stop button, the vehicle disappearing from the feed, or a line change. This ends the Live Activity, cancels the scheduled notification, silences speech, and restores the tab bar, the flat style and the region camera.
- S10 Speech: `AVSpeechSynthesizer` with a `ca-ES` voice and the `.playback` + `.duckOthers` session, foreground only (no background audio mode). Voice on/off is persisted (`followVoiceEnabled`, default on).
- S11 Preserve:
  - router focus and the vehicle sheets;
  - nothing new on the 10 Hz path (Equatable views, derived state on human-scale events);
  - PerfTelemetry/FrameMonitor;
  - the Tot GlobalZoom hysteresis;
  - Catalan accessibility labels and 44 pt targets;
  - every existing test green.

## Tasks

| ID | Specs | Route | Status | Commit |
|----|-------|-------|--------|--------|
| T0 | contracts | inline (parent): `Core/Follow/FollowModels.swift`, `FollowSession` signatures, `FollowCoordinator` API, the service and view stubs, compiled on CI before the writers | in progress | — |
| T1 | S5–S7 logic, S9 | pane `follow-core`: `FollowSession` rules + `FollowCoordinator` behaviour + tests | pending | — |
| T2 | S8, S10 | pane `follow-system`: announcer, follow Live Activity (attributes, controller, widget, project.yml), alight scheduler. Risk item 5 (build config) | pending | — |
| T3 | S4–S7 UI | pane `follow-ui`: HUD, panel, event cards, map stop labels | pending | — |
| T4 | S1–S3 metro + bus | pane `follow-mb`: MapScreen + BusMapScreen integration, snapshot builders, tests | pending | — |
| T5 | S1–S3 FGC | pane `follow-fgc`: FGCMapScreen integration, snapshot builder, tests | pending | — |
| T6 | S11 + verify | parent + independent verifier, PR, TestFlight | pending | — |

## Log

- L1 2026-11-06 (request, verbatim): "perfecto, quiero poder seguir un metro o bus que i me vaya anunciando las paradas, i que el seguimiento en vivo, sea estilo sims city preparalo" → v7 mockups.
- L2 2026-11-06 (verbatim): "me encanta, a por ello y luego testflight". Defaults taken for the open points: voice only in the foreground; bus uses estimated positions; no speed or exit side; metro + bus + FGC from day one.
- L3 Read-only map (pane follow-map, scratchpad `follow-map-report.md`):
  - the follow exists in the three maps as 2D region centring on the 10 Hz tick;
  - `TrainPosition` gives next stop, seconds, route distance and heading;
  - FGC has `nextStopCodes` but no ETA;
  - no speed or exit side in any feed;
  - the Live Activity infra exists (one arrival activity, local updates);
  - no AVFoundation usage; `UIBackgroundModes = [fetch]` only;
  - time-sensitive notifications would need an entitlement and a new provisioning profile.
- L4 Decisions:
  - D1 FGC shows stop names without minutes and triggers by stop sequence.
  - D2 No speed or exit side (no data).
  - D3 Regular notification. Time-sensitive needs a new signed profile, and adding the entitlement without one breaks the TestFlight archive.
  - D4 A follow Live Activity supersedes the arrival one.
  - D5 A pan pauses the chase camera, not the session.
