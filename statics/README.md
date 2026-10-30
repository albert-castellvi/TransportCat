# CatTrans static assets

69 original SVG assets (including 12 bus markers): 20 outline icons, 11 line badges, 4 map markers and two sets of 11 directional train markers (also exported as 3× PNG).
Open `index.html` for the gallery; `manifest.json` lists dimensions and metadata.

## Usage

Icons use a 24×24 viewBox, transparent background and `currentColor`. When used
as an external image, color defaults to black; inline SVG inherits CSS color.
Line badges are 64×40 and use the exact colors in
`TransportCat/Core/Models/MetroLine.swift`, with black or white text chosen for contrast.
Markers are 40×40 with a white outline and default L5 blue; duplicate and change
the background fill to the relevant line color when integrating.

These are original app assets, not official TMB logos. Badge text uses system fonts.
For SwiftUI, convert SVGs to PDF or PNG and import them into an asset catalog;
no app integration or replacement of existing SF Symbols is included here.

## Semantics

Keep accessible, unavailable and unknown accessibility distinct. Never interpret
missing station data as inaccessible. Entrance, elevator, stairs and escalator
icons are future-use only: their existence does not establish a station facility.
No additional transport modes or station-specific facilities are inferred.

## Directional map trains

See `map-trains/README.md`, `map-trains/preview.png` and
`map-trains/motion-preview.html` for the moving-train asset set.

## Set 02 — Top-down articulated trains

See `map-trains-v2/README.md` and `map-trains-v2/preview.png` for a slimmer alternative.

## Bus markers

See `map-buses/README.md` and `map-buses/preview.png` for the bus set.
Bus colors are illustrative, not inherited from metro lines.
