# UI assets: apply the statics/ icon set to the map, lines and tabs
Objective: use the new original assets in `statics/` in the app (directional train markers, line badges, station and terminal markers, tab and status icons).
Branch: feat/ui-assets (from main) · Delivery: ask-on-risk · Test runner: XCTest, Linux `swift test` for engine code, macOS CI for the rest.
Status: approved by user 2026-10-30 ("aplicalos al mapa, lineas... revisa antes el video"). Delegated to pi workers.

## Specs
- S1 Train markers. On the map each train is the image `statics/map-trains/<line>@3x.png` (asset `train-<line>`, rendered 36x30 pt, anchored at its center on the coordinate), rotated to face its direction of travel along the route. The destination label stays upright and separate from the rotated image (README of map-trains).
- S2 Heading. `TrainPosition.heading` is the route bearing in degrees clockwise from north, in 0..<360, in the travel direction (forward = toward the last station), measured over a short window of the polyline (about 15 m behind to 15 m ahead of the displayed distance) so sharp vertices do not flip it. `TrainMotion` publishes it for the interpolated position. On screen the image rotates by `heading - 90 - mapCameraHeading` degrees (the images face east; the map may be rotated by the user).
- S3 Labels. The destination label is shown only when the visible latitude span is below 0.05 degrees (zoomed in); zoomed out, only the images are drawn (video of build 19: labels overlap on L1). Assumption: not asked for explicitly, it avoids clutter that the larger images would worsen.
- S4 Station markers. Stations on the map use the asset marker tinted with the line color (`statics/markers/station.svg`, terminal variant `station-terminal.svg` for the first and last station of the line), replacing `StationDot`. Interchange markers are NOT used: the app has no interchange data (TMB `corresp` endpoint is dead), so none is invented.
- S5 Line picker. Each chip is the badge image `statics/lines/<line>.svg` (asset `badge-<line>`): selected = full opacity with a white ring, others = opacity 0.45. Keep the accessibility label and selected trait.
- S6 Tab and status icons. Tab bar: `icons/map.svg`, `icons/network.svg`, `icons/service-alert.svg` (template images) instead of SF Symbols. `AlertBanner` uses the service-alert icon; the diagram's accessible label uses `icons/accessible.svg`. Accessibility semantics stay as they are (no state is invented from missing data).
- S7 Assets pipeline. `scripts/render-assets.sh` renders the SVGs to PNG @3x with `rsvg-convert` into `TransportCat/Resources/Assets.xcassets/*.imageset` (PNGs committed; script re-runnable). `<line>` is `MetroLine.displayName` lowercased (l1 ... l9n, l10s, l11, fm).
- S8 No regression. Existing tests keep passing; all text, colors, behavior and accessibility labels not named above stay unchanged. A unit test checks that every asset name used exists in the catalog for every `MetroLine`.

Out of scope: Xarxa diagram markers, interchange markers, other icons of `statics/icons/` (future use), new screens, `statics/` index/preview files in the app.

## Tasks
| ID | Specs | Route | Model / effort | Status | Commit |
|----|-------|-------|----------------|--------|--------|
| T1 | S2 | delegated (engine, local `swift test`), surfaces: GeoMath.swift, TrainPositionEngine.swift, TrainMotion.swift, engine tests | nan/deepseek-v4-flash, medium | pending | - |
| T2 | S1 S3 S4 S5 S6 S7 S8 | delegated (assets script + SwiftUI), surfaces: scripts/, Assets.xcassets imagesets, MapScreen/LinePicker/RootView/AlertBanner/DiagramScreen, AssetCatalogTests | nan/qwen3.8-flash, medium | pending, codes against `TrainPosition.heading` from T1 | - |

## Log
- L1 (2026-10-30, user): "te paso video de la nueva version se han añadido una serie de iconos en la carpeta statics, aplicalos al mapa, lineas... revisa antes el video"
- L2 (2026-10-30, orchestrator): video of build 19 reviewed: markers now sit on the track, camera fit works, labels overlap at low zoom on L1. Assets inspected: map-trains face east (anchor center, rotate by route tangent), badges 64x40 contain `<text>` (SVG-in-catalog text support is unreliable), so everything is pre-rendered to PNG @3x with rsvg-convert. Station markers default to L5 blue `#005A97` and must be re-tinted per line.
