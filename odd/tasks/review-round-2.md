# Review round 2 fixes (2026-11)

Objective: fix the bugs and contained UX issues from the 2026-11-12 review (GitHub issues #65-#104), then ship to TestFlight.
Delivery: one commit per issue on a worktree branch per unit (`fix/review-round-2-<unit>`), merged into `fix/review-round-2`; PR to `main`, whose merge uploads to TestFlight. Tests: XCTest in `Tests/TransportCatTests` (CI on macOS is the only full compile; Foundation-only files also build on Linux).

## Specs

- S1: "haz un repaso de bugs i mejoras del repo"
- S2: "revisa cada seccion de las capturas, hay mas mejoras para hacer"
- S3: "empieza a lanzar subagentes, hay nuevo modelos en NaN asi, revisalos, revisa los costes (lo tienes en la docu de nan) i empieza a solucionar issues, cuando este todo, a testflight"
- S4: each issue body on GitHub is the spec of its fix.

## Tasks

| ID | Unit | Issues | Route | Status |
|----|------|--------|-------|--------|
| T1 | identity | #65 #68 #69 #70 #73 #74 (S4) | pi, nan/deepseek-v4-pro, worktree | in progress |
| T2 | core | #66 (store) #67 #71 #72 #75 #79 #85 #86 #87 #88 (S4) | pi, nan/deepseek-v4-flash, worktree | in progress |
| T3 | explore | #66 (UI) #81 #84 #92 #95 #96 #97 #98 (S4) | pi, nan/hy4, worktree | in progress |
| T4 | maps | #76 #78 #80 #82 #83 #89 #90 #91 #94 #99 #100 (S4) | pi, nan/glm5.3, worktree | in progress |
| T5 | infra | #77 #103 #104 (S4) | inline | pending |
| T6 | merge + QA | merge T1-T5, Linux build of the Foundation-only files, independent read-only QA (S3) | inline + pi QA | pending |
| T7 | ship | PR, CI green, merge to main, TestFlight upload (S3) | inline | pending |

Deferred, not in this batch: #93 (metro marker zoom levels, needs a device-driven design pass), #101 (Tot station sheet), #102 (localization), the Dynamic Type half of #99, favourites reordering in #97.

## Log

- L1 (2026-11-12, user): "haz un repaso de bugs i mejoras del repo"
- L2: four read-only pi reviewers (nan/deepseek-v4-flash) reported 26 bugs and 26 improvements; the 12 medium ones and 10 low ones were re-read inline and hold. A UX pass over the code and 12 device screenshots added the interchange-badge bug (#65) and the UX items.
- L3 (2026-11-12, user): "adelante" (file the issues) and then S3. Issues #65-#104 filed.
- L4: models by NaN price (USD per 1M tokens, input/output/cached read, from `~/.pi/agent/models.json`): deepseek-v4-flash 0.28/1.12/0.006, glm5.3-flash 0.14/0.47/0.24, qwen3.8-flash 0.20/0.63/0.02, mimo-v2.6-flash 0.19/0.37/0.004, hy4 1.11/3.34/0.06, glm5.3 1.31/4.11/0.24, deepseek-v4-pro 1.76/5.28/0.06, qwen3.8-max 2.67/8.00/0.33, kimi-k3.1-pro 2.67/13.34/0.27. Agent sessions are dominated by cached reads, so the cached price decides. Mechanical Core unit on deepseek-v4-flash; the identifier-logic unit on deepseek-v4-pro; the two SwiftUI units, which no local compiler checks, on larger models (hy4, glm5.3).
