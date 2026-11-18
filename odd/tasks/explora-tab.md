# Explora as a regular tab, readable cards, planner next
Explora stops being the collapsing search-role tab: it becomes a normal fourth tab so the map is always one visible tap away. Slice 1 (this branch) fixes navigation, contrast and overlapping cards; slice 2 (separate branch) redesigns the planner with real address search.

## Specs
- S1 "echale un ojo al boton para volver al mapa, el contraste (eso pasa en varios puntos es muy malo y no se ve con el fondo negro i unas veces sale el mapa otro sale el icono de los avisos" — verified on a real iPhone (build 107): the collapsed search tab shows the last used tab's icon (Avisos or Mapa) in a translucent glass circle with a dark icon over black, almost invisible.
- S2 "A, pestaña normal lo que tu veas, desarolla, testea i sube a testflight" — Explora is a regular tab with the four tabs always visible; the search field lives in Explora's navigation bar.
- S3 "mirar como se montan las cajas, que se solapan" — in "A prop" the nearby cards touch with no gap and their rounded corners collide; the floating bar also covered the last card.
- S4 (slice 2, not here) "que se pueda buscar una direccion real que en esa direccion te diga las opciones, rediseñar como el resto con el logo de fondo" — planner with MapKit address search and the network-motif background.

## Tasks
- T1 RootView: Explora `Tab` without `role: .search` (S1, S2)
- T2 ExploreScreen: search field in the navigation bar; remove the map-button hack, `isSearchPresented` and its constants (S1, S2)
- T3 Nearby cards: gap between cards, no colliding corners, nothing under the bar (S3)
- T4 Verify on the Mac simulator: build, full test suite, tours (S1-S3)

## Log
- L1 (2026-11-18, user): "A, pestaña normal lo que tu veas, desarolla, testea i sube a testflight, quiero enviar hoy a revision de apple"
- L2: decision: planner redesign (S4) is a separate slice so today's review submission carries only the verified navigation fix.
