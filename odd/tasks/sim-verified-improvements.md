# Simulator-verified improvements

First batch developed with a real compiler and simulator (remote MacBook Pro, Xcode 26.3) instead of CI-only compiles.
Branch `feat/sim-verified-improvements`. Workers are pi sessions in herdr panes; the orchestrator builds, tests and screenshots on the Mac.

## Specs

- S1 (user, 2026-11-12): "ahora ya tienes ojos para desarrollar la app testear i implementar TODAS las mejoras que puedas, sin limite pero a coste 0 siempre"
- S2 (user, 2026-11-12): "el trabajo pesado, lo hace pi recuerda, tu funcion es pensar i orquestrar"
- S3 (user, 2026-11-12): "para el desarrollo con pi usa el modelo que estimes adecuado, es una sub ya pagada, si se puede usar qwen3.6 genial pero hay modelos muuuucho mejores"
- S5 (user, 2026-11-12): "dentro de lo posible usa modelos flash que son mas baratos, solo usa los top si es necesario"
- S6 (user, 2026-11-12): "revisa tambien cuando termines con todo eso el UI/UX, en profundidad, no te quedes a la superficie dejalo todo muy muy bien hilado, como he dicho tiene via libre, el unico limite es que el coste sea 0 (aparte de las sub de IA) tienes prohibido pagar nada"
- S7 (user, 2026-11-12): "no te olvides del widget i de la app de applewatch"
- S4: each open GitHub issue body is the spec of its fix (#74 #78 #93 #96 #97 #99 #101 #102).

## Tasks

| ID | What | Specs | Route | Status |
|----|------|-------|-------|--------|
| T1 | UI tour driver (`UITests/TourUITests.swift`, scheme `TransportCatTour`) | S1 | inline | done, in use |
| T2 | #74 one TMB client per station sheet | S4 | inline | done (builds; request saving not measured) |
| T3 | #101 Tot station dots open the station sheet | S4 | inline | done, seen in simulator |
| T4 | #99 Dynamic Type in the chrome | S4 | pi nan/qwen3.6 | done (builds; the tab-bar accessory does not grow, iOS pins it; pickers not captured) |
| T5 | #97 favourites reorder, one nearby list | S4 | pi nan/deepseek-v4-pro | done, seen in simulator (one regression fixed) |
| T6 | #96 destination can be the current location | S4 | pi nan/qwen3.6 | done, seen in simulator (three logic bugs fixed on review) |
| T7 | #93 metro station markers by zoom band | S4 | pi nan/glm5.3 | done, seen in simulator (threshold recalibrated from a measurement) |
| T8 | Station sheet neutral countdown, attribution chip off the Maps legal mark | S1 | pi nan/qwen3.8-flash | done, seen in simulator (FGC map chip not captured) |
| T9 | Deep UI/UX review: app screens, widget + Live Activity, watch app | S6 S7 | 3 read-only pi reviewers (flash), findings checked in the simulator | running |
| T10 | Fixes from T9 | S6 S7 | pi flash workers, verified on the Mac | pending |
| T11 | #78 capture `arrivalsByStop` with live data | S4 | pending | pending |
| T12 | #102 localization (es, en), separate branch | S4 | pi, after T10 | pending |

## Log

- L1 (2026-11-12, user): S1.
- L2: baseline on the Mac: `xcodebuild test` on main (316109a) green on iPhone 17 Pro / iOS 26.3.
- L3: "coste 0" first read as free models only (`nan/qwen3.6`, `nan/gemma4` are priced 0 in `~/.pi/agent/models.json`); S3 then cleared the paid-subscription NaN models. No other spend: no paid APIs, no new services.
- L4: T2-T3 and the tour driver were written inline before S2 arrived; from S2 on, implementation goes to pi workers.
- L5: first batch merged on the branch (cherry-picks, no conflicts) and verified on the Mac: `xcodebuild test` 597 tests, 0 failures; each change looked at in simulator screenshots through the tour driver.
- L6: what only the simulator caught: the #93 threshold (worker estimated 0.36 deg for the whole-L1 view, measured about 0.22, so the dot band never showed); the Explora nearby list rendering its empty state because the embedded list raced the screen's catalog load. What review of the diff caught: the planner pick function never assigned the picked endpoint.
- L7: free `nan/qwen3.6` was enough for the mechanical unit (a11y) and not for the logic unit (planner), which needed the exact function spelled out.
- L8: no push, no PR yet: both are the user's call.

