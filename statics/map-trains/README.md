# Moving train map markers

11 original vector train markers with transparent 3× PNG exports (180×150).
Based on the supplied Andana screenshot concept, not copied assets or exact rolling stock.
The three-car silhouette, cab windshield, headlights and line-color bands remain
legible on dark and light maps. PNGs are intended to render at 36×30 points or pixels.

## Integration contract

- The train faces east (right); anchor at the center (0.5, 0.5).
- Rotate by the route tangent, not the destination label. For screen-coordinate
  deltas use atan2(dy, dx) in degrees. For a geographic bearing measured clockwise
  from north, use bearing - 90 degrees; account for camera rotation as appropriate.
- Move the annotation position using actual route geometry and timestamped data.
  Do not animate the SVG internally: the map owns position and heading.
- Smooth headings across the 0/360 boundary using the shortest angular delta.
- Keep labels upright and separate from the rotated pictogram.
- Handle missing or stale real-time positions separately; these assets do not
  establish live-data availability or implement movement in the application.

Open `motion-preview.html` for a standalone illustrative movement demo, with pause
control and reduced-motion support. Routes and animation timing are synthetic.
`preview.png` compares all variants on dark and light backgrounds.
