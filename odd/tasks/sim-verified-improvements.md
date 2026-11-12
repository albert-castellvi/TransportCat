# Simulator-verified improvements

First batch developed with a real compiler and simulator (remote MacBook Pro, Xcode 26.3) instead of CI-only compiles.
Branch `feat/sim-verified-improvements`. Workers are pi sessions in herdr panes; the orchestrator builds, tests and screenshots on the Mac.

## Specs

- S1 (user, 2026-11-12): "ahora ya tienes ojos para desarrollar la app testear i implementar TODAS las mejoras que puedas, sin limite pero a coste 0 siempre"
- S2 (user, 2026-11-12): "el trabajo pesado, lo hace pi recuerda, tu funcion es pensar i orquestrar"
- S3 (user, 2026-11-12): "para el desarrollo con pi usa el modelo que estimes adecuado, es una sub ya pagada, si se puede usar qwen3.6 genial pero hay modelos muuuucho mejores"
- S4: each open GitHub issue body is the spec of its fix (#74 #78 #93 #96 #97 #99 #101 #102).

## Tasks

| ID | What | Specs | Route | Status |
|----|------|-------|-------|--------|
| T1 | UI tour driver (`UITests/TourUITests.swift`, scheme `TransportCatTour`) | S1 | inline | built, pending first run |
| T2 | #74 one TMB client per station sheet | S4 | inline | written, pending Mac build |
| T3 | #101 Tot station dots open the station sheet | S4 | inline | written, pending Mac build |
| T4 | #99 Dynamic Type in the chrome | S4 | pi nan/qwen3.6, worktree v-a11y | running |
| T5 | #97 favourites reorder, one nearby list | S4 | pi nan/deepseek-v4-pro, worktree v-explore | running |
| T6 | #96 destination can be the current location | S4 | pi nan/qwen3.6, worktree v-planner | running |
| T7 | #93 metro station markers by zoom band | S4 | pi nan/glm5.3, worktree v-map | running |
| T8 | Visual pass over every screen in the simulator, fix what it shows | S1 | orchestrator looks, pi fixes | pending |
| T9 | #78 capture `arrivalsByStop` with live data | S4 | pending | pending |
| T10 | #102 localization (es, en) | S4 | pi, after T4-T7 merge | pending |

## Log

- L1 (2026-11-12, user): S1.
- L2: baseline on the Mac: `xcodebuild test` on main (316109a) green on iPhone 17 Pro / iOS 26.3.
- L3: "coste 0" first read as free models only (`nan/qwen3.6`, `nan/gemma4` are priced 0 in `~/.pi/agent/models.json`); S3 then cleared the paid-subscription NaN models. No other spend: no paid APIs, no new services.
- L4: T2-T3 and the tour driver were written inline before S2 arrived; from S2 on, implementation goes to pi workers.
