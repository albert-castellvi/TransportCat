# Bug review fixes (2026-11)

Objective: fix the verified bugs from the 2026-11-09 bug review, tracked as GitHub issues #24-#61. Branch: `fix/bug-review`; one worktree branch per unit (`fix/bug-review-<unit>`), merged back by the orchestrator.
Delivery: one commit per issue (`Fixes #N`), units merged into `fix/bug-review`; push and PR are the user's decision. Test runner: XCTest in `Tests/TransportCatTests`, runs only in CI (macOS); local check is `swiftc -parse` on Linux.

## Specs

- S1: "lanza los subagentes de PI con las issues". Each issue body on GitHub is the spec for its fix: summary, location, failure scenario, and suggested fix.
- S2: Scope is the 31 issues verified as real, excluding #39. The six `needs-repro` issues (#26, #40, #42, #43, #50, #58) are out of scope until reproduced.
- S3: #39 (widget place suggestions) is out of scope: the fix needs a new App Group (entitlements, `project.yml`, Apple Developer portal, CI signing). This is pending a user decision.
- S4: Each fix adds one deterministic XCTest that fails before the fix, when the logic is testable without UI. View-only fixes explain why they have no test.

## Tasks

| ID | Unit | Issues | Route | Status | Commits |
|----|------|--------|-------|--------|---------|
| T1 | station | #24 #25 #28 #45 #46 #47 #48 | delegated (pi, deepseek-v4-flash, worktree) — parallel unit | done, QA passed | 837d192 b675de9 0ea0ec1 a91368d 7f6ee7c 3c82ee6 e8d8fa5 f29df27 |
| T2 | fgc | #29 #32 #33 #35 #49 #51 #57 #60 | delegated (pi, deepseek-v4-flash, worktree) — parallel unit | done, QA passed | 4cca427 5b97b53 39c0b90 d696ab7 bbe0733 8c8bec3 9f7bcad 3b1cf6c |
| T3 | map | #27 #31 #34 #38 #44 #52 #54 #55 #59 | delegated (pi, deepseek-v4-flash, worktree) — parallel unit | done, QA passed | f9368b8 6591aa0 0249890 c3703b8 cd131e0 2369f2c 0ac24f3 31439f4 1bc2073 |
| T4 | misc | #30 #36 #37 #41 #53 #56 #61 | delegated (pi, deepseek-v4-flash, worktree) — parallel unit | done, QA passed | fa4bbaa d6a5390 dff49a7 ace68bc 1a69060 f59b7d7 466daea |
| T5 | merge | merge T1-T4 into `fix/bug-review`, resolve conflicts, `swiftc -parse` all changed files | inline | done | merges up to 8faef31 |
| T6 | qa | independent read-only verification of the 31 fix commits | delegated (pi, deepseek-v4-flash) | done: 3 blockers corrected, #35 reverted | d5a97ab 752e0b0 b417910 + station sheet fix |

## Log

- L1 (2026-11-09, user): "antes de arrancar relee claude.MD con las nuevas reglas, tras ello lanza los subagentes de PI con las issues"
- L2: Pi has no subagent extension installed, so the workers are `pi` sessions in herdr panes on `nan/deepseek-v4-flash`. Units share some files (StationDetailView, ExploreArrivals, NextArrivalsFetcher, AppModel), so each unit runs in its own git worktree.
- L3: All 4 units finished with 31 fixed and 0 skipped, one commit per issue with `Fixes #N` and no attribution. The merges were clean (ExploreArrivals.swift auto-merged coherently), and `swiftc -parse` passes on all 49 changed Swift files.
- L4: Orchestrator review of #24 found a regression introduced by the fix. The new `stationFeedCache` on the TMBClient shared by every screen was mutated from a nonisolated async function (Swift 5 mode, so it ran off the main actor). Fixed in f29df27 (`@MainActor` on the cache and `stationFeed`).
- L5: QA reported 3 blockers. #37 did not compile (variadic `CharacterSet(charactersIn:)`): fixed in d5a97ab. #24's bridge got display names ("L1") as line codes, so the station feed returned 404 and the bridge silently fell back to ID_ESTACIO; the watch had the same request: fixed in 752e0b0 with 2 tests. #35's fix made the documented "NO" not-stopped sentinel unreachable, because the catalog always contains station NO: reverted in b417910, and #35 stays open pending live data. Note: d696ab7 still carries "Fixes #35", so drop it from the squash message.
- L6: The scoped recheck closed #37 and #35. The #24 station-sheet arrivals still fell back to ID_ESTACIO without a feed; a second and last correction now resolves the sheet's code with `stationCode(forStation:in:)`. Pending: CI compile and tests, which need a PR (the user's decision); #39 (App Group decision); #35 (live data); the 6 needs-repro issues.
- L7 (2026-11-09, user): "empieza por compilar todo". Xcode cannot run on Linux, so a scratch SwiftPM package (outside the repo) was built from the 66 app files that need only Foundation/Observation, plus a FoundationNetworking re-export shim. 11 changed app files compile for real. 38 of 52 test files compile (the rest need SwiftUI/UIKit/UserNotifications). Result: 446 tests executed, 0 failures, including 11 of the 27 new tests of this branch. The #24 display-name test was shown RED without the fix (asked "101") and GREEN with it ("128"). The Linux compile caught one more defect: PersistedModeTests (#44) mutated main-actor properties from the nonisolated setUpWithError, so it did not compile; fixed with async setUp/tearDown. Still uncompiled: the 70 SwiftUI/UIKit files (18 changed app files, 16 new tests), which only CI on macOS can build.
