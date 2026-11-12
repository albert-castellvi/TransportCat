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
- S8 (user, 2026-11-12): "prueba el seguimiento de trenes i las notificaciones que funcionen bien tambien"
- S9 (user, 2026-11-12): "enviame norificacion a la app movil con cada punto finalizado"
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
| T9 | Deep UI/UX review: app screens, widget + Live Activity, watch app | S6 S7 | 3 read-only pi reviewers (flash) | done: 19 + 18 + 18 findings |
| T10 | Fixes from T9: sheets, flow, maps, explore, parades, widget, watch (pass 1) | S6 S7 | 7 pi flash workers | merged; app + widget + watch build; 639 tests green before the maps and explore commits; visual check in progress |
| T13 | Follow and notifications tested in the simulator | S8 | tour driver | follow works; Live Activity countdown froze (fix written, unverified); reminder test rerunning |
| T14 | Follow camera above the sheet, compact vehicle sheets, leading sheet titles | S8 | pi nan/deepseek-v4-flash, worktree ux-follow | running |
| T15 | Watch pass 2 (shared code: W3, W7, W16, W17, W18), widget on a home screen, watch app on a watchOS simulator | S7 | pending | pending |
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
- L9: the Mac slept mid-session (pmset sleep 10) and dropped off the network; the user woke it and asked that neither the Mac nor its display sleep. Set `pmset -a sleep 0 disksleep 0 displaysleep 0 disablesleep 1` plus a background `caffeinate -dims`. To restore at the end: `sleep 10 disksleep 10 displaysleep 10 disablesleep 0` and kill caffeinate. The simulator was shut down by the sleep and had to be booted again.
- L10: compile errors the Mac caught in the UX batch, fixed inline (a few lines each): an invented `sensoryFeedback(_:_:)` form in three sheets, a `let` scoped inside an HStack and read outside it, an optional caption in Explora.
- L11: a worker on qwen3.8-flash edited the main checkout instead of its worktree; its three files were moved with `git diff | git apply` and the brief now says "use only relative paths".
- L12: runtime findings from the follow and notification tests: the followed train is centred under the sheet (T14); the Live Activity countdown was a static string after the widget unit's F5 and froze in the background; the denied-permission message works. The first reminder run was invalid: the driver matched "No permitir" for "Permitir".

