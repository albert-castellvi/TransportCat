# Rodalies at the same quality as the other services
Rodalies (Renfe) looks worse than metro, bus and FGC: its trains look stopped and its stops list is ugly. A read-only review (2026-11-18) found the causes. Slice 1 redesigns the stops list; slice 2 makes the map honest; slice 3 makes it alive.

## Specs
- S1 "rodalies parece que todos los trenes salen parados i en el listado de la paradas es 'feo'"
- S2 "arreglalo todo si deja rodalies con la misma calidad del resto de servicios"
- S3 Cause of S1 (measured on the live feed): Renfe publishes the coordinate of the stop, not a GPS fix, for most trains (55 of 109 share an exact coordinate; 84 % do not change in 43 s; no speed or bearing); the app animates the resulting stop-to-stop jump over 30 s and then freezes it, and draws stacked trains as one. Also `nextStopID` is wrong for IN_TRANSIT_TO and the freshness chip counts the poll, not the position.

## Tasks
- T1 Stops list redesign: opaque card, direction band, 64 pt rows, hierarchy, "+N" trains, other-line badges, empty states, contrast (slice 1, branch feat/rodalies-list)
- T2 Map honesty: position age, grouped trains, no 30 s glide for jumps, nextStopID, far-point sanity (slice 2, branch feat/rodalies-honesty)
- T3 Alive map: interpolate with trip-update ETA and the published schedule (slice 3, after T2)
- T4 Follow-ups: R1 terminus data check, Metro bridge for interchanges

## Log
- L1 (2026-11-18, user): "rodalies parece que todos los trenes salen parados i en el listado de la paradas es 'feo' puedes mandar a un agente a revisar ?"
- L2 (2026-11-18, user): "arreglalo todo si deja rodalies con la misma calidad del resto de servicios"
- L3: full review with feed samples and design: scratchpad rod-review-out/REPORT.md (copied into the repo docs only if useful)
