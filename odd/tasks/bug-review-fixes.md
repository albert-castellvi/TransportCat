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
| T1 | station | #24 #25 #28 #45 #46 #47 #48 | delegated (pi, deepseek-v4-flash, worktree) — parallel unit | done, QA pending | 837d192 b675de9 0ea0ec1 a91368d 7f6ee7c 3c82ee6 e8d8fa5 f29df27 |
| T2 | fgc | #29 #32 #33 #35 #49 #51 #57 #60 | delegated (pi, deepseek-v4-flash, worktree) — parallel unit | done, QA pending | 4cca427 5b97b53 39c0b90 d696ab7 bbe0733 8c8bec3 9f7bcad 3b1cf6c |
| T3 | map | #27 #31 #34 #38 #44 #52 #54 #55 #59 | delegated (pi, deepseek-v4-flash, worktree) — parallel unit | done, QA pending | f9368b8 6591aa0 0249890 c3703b8 cd131e0 2369f2c 0ac24f3 31439f4 1bc2073 |
| T4 | misc | #30 #36 #37 #41 #53 #56 #61 | delegated (pi, deepseek-v4-flash, worktree) — parallel unit | done, QA pending | fa4bbaa d6a5390 dff49a7 ace68bc 1a69060 f59b7d7 466daea |
| T5 | merge | merge T1-T4 into `fix/bug-review`, resolve conflicts, `swiftc -parse` all changed files | inline | done | merges up to 8faef31 |
| T6 | qa | independent read-only verification of the 31 fix commits | delegated (pi, deepseek-v4-flash) | running | |

## Log

- L1 (2026-11-09, user): "antes de arrancar relee claude.MD con las nuevas reglas, tras ello lanza los subagentes de PI con las issues"
- L2: Pi has no subagent extension installed, so the workers are `pi` sessions in herdr panes on `nan/deepseek-v4-flash`. Units share some files (StationDetailView, ExploreArrivals, NextArrivalsFetcher, AppModel), so each unit runs in its own git worktree.
- L3: All 4 units finished with 31 fixed and 0 skipped, one commit per issue with `Fixes #N` and no attribution. The merges were clean (ExploreArrivals.swift auto-merged coherently), and `swiftc -parse` passes on all 49 changed Swift files.
- L4: Orchestrator review of #24 found a regression introduced by the fix. The new `stationFeedCache` on the TMBClient shared by every screen was mutated from a nonisolated async function (Swift 5 mode, so it ran off the main actor). Fixed in f29df27 (`@MainActor` on the cache and `stationFeed`).
