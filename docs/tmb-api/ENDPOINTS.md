# TMB public API — endpoint inventory

> Live-verified corrections (2026-10-29) are in [LIVE-AUDIT.md](LIVE-AUDIT.md) and take precedence over this file: e.g. `/linies/metro/{code}/trams` does answer 200, `elements/superficie/{tipus}` takes `PARADES`-style names, and lettered metro lines use numeric codes (L9N = 94).

Base URL: `https://api.tmb.cat/v1/`
Auth: `app_id` + `app_key` query params on every call (API-Key scheme, no OAuth).
Research date: 2026-10-29. No authenticated call was made while compiling this file.

## Confidence tags

| Tag | Meaning |
| --- | --- |
| `seen-in-working-code` | A client calls this exact template **and** there is runtime evidence (live HTTP capture stored in a repo, passing tests, or a deployed app). |
| `docs-only` | Documented, but not observed live in the sources reviewed. Sub-tagged in the source column: `[official swagger]` = fetched from TMB's own published Swagger 2.0 asset; `[code]` = only appears in third-party client source. |
| `guess` | Inferred from context. Nothing below is tagged `guess` except where explicitly noted. |

## Key discovery: the official Swagger specs are public static assets

`developer.tmb.cat` pages require login, but the Swagger 2.0 JSON assets they render are **not** gated:

- `https://developer.tmb.cat/assets/api-docs/v1/transit/swagger.json` → HTTP 200, 135 402 bytes
- `https://developer.tmb.cat/assets/api-docs/v1/ibus/swagger.json` → HTTP 200, 7 325 bytes
- `https://developer.tmb.cat/assets/api-docs/v1/ibus_legacy/swagger.json` → HTTP 200, 6 938 bytes
- `https://developer.tmb.cat/assets/api-docs/v1/imetro/swagger.json` → HTTP 200, 8 749 bytes
- `https://developer.tmb.cat/assets/api-docs/v1/planner/swagger.json` → HTTP 200, 29 398 bytes
- `https://developer.tmb.cat/assets/api-docs/v1/static/swagger.json` → HTTP 200, 1 492 bytes

Probed and **not** public (302 → `auth.tmb.cat` OIDC): `alerts`, `alertes`, `avisos`, `incidencias`, `status`, `news`, `noticies`, `realtime`, `realtimebus`, `airquality`, `bicing`, `parkings`, `tram`, `fgc`, `renfe`, `rodalies`, `imetro_legacy`, `transit_legacy`, `planner_legacy`. So there is no public `alerts` spec — see the [`alerts`](#alerts) section.

Line numbers in the source column below refer to those downloaded JSON documents (pretty-printed, `paths` under `^    "/..."`).

---

## transit — `basePath: /v1/transit`

Swagger: `https://developer.tmb.cat/assets/api-docs/v1/transit/swagger.json`, 40 documented GET paths. All responses are GeoJSON `FeatureCollection`; `geometry` is present on every entity. Global query params: `app_id`, `app_key`, plus `srsName=EPSG:XXXX` to change CRS (default `EPSG:4326`) and `filter=FIELD=value` on list endpoints.

| Method | Path | Returns | Source | Confidence |
| --- | --- | --- | --- | --- |
| GET | `/linies/metro` | All metro lines as features; **geometry = `MultiLineString` (the whole line path)** | swagger `paths./linies/metro` (sw_transit.json:667); live capture `tests/fixtures/metro_lines.json` via `tests/fixtures/metro_lines.meta.json:6` (apikurt/pytmb) | seen-in-working-code |
| GET | `/linies/metro/{codi_linia}` | Single metro line (same feature shape, incl. geometry) | transit intro ("filtrar … indicant com a última part del path el codi", `https://raw.githubusercontent.com/apikurt/pytmb/HEAD/tests/fixtures/metro_lines.meta.json` uses `filter=CODI_LINIA=1` instead); aalises `src/datasources/MetroDataSource.ts:137` | docs-only [official swagger] — path form is documented in the intro, not as a `paths` entry |
| GET | `/linies/metro/{codi_linia}/recs` | Metro route records, both directions (anada/tornada), one feature per `ID_REC_LINIA` | swagger `paths./linies/metro/{codi_linia}/recs` (sw_transit.json:893) | docs-only [official swagger] |
| GET | `/linies/metro/{codi_linia}/trams` | Segments between stations (`TramMetro`: `ID_ESTACIO_INI/FI`, `LONGITUD`, `ORDRE_TRAM`) | swagger `paths./linies/metro/{codi_linia}/trams` (sw_transit.json:919) | docs-only [official swagger] — **reported live as HTTP 404**, treat as removed/decommissioned |
| GET | `/linies/metro/{codi_linia}/estacions` | Stations of one metro line (Point geometry) | swagger (sw_transit.json:690); live capture `tests/fixtures/metro_stations_discovery.meta.json:6` (apikurt/pytmb); xavivg91 `R/metro.stations.R:53` | seen-in-working-code |
| GET | `/linies/metro/{codi_linia}/estacions/central` | Same stations, central-point geometry | swagger (sw_transit.json:717) | docs-only [official swagger] |
| GET | `/linies/metro/{codi_linia}/estacions/{codi_estacio}/accessos` | Accesses of one station of a line | swagger (sw_transit.json:743) | docs-only [official swagger] |
| GET | `/linies/metro/{codi_linia}/estacions/{codi_estacio}/accessos/fisics` | Physical accesses of one station of a line | swagger (sw_transit.json:773) | docs-only [official swagger] |
| GET | `/linies/metro/{codi_linia}/estacions/{codi_estacio}/accessos/{codi_acces}/corresp` | Correspondences of one access | swagger (sw_transit.json:803) | docs-only [official swagger] |
| GET | `/linies/metro/{codi_linia}/estacions/{codi_estacio}/corresp` | Correspondences of one station of a line | swagger (sw_transit.json:836) | docs-only [official swagger] |
| GET | `/linies/metro/{codi_linia}/horaris` | General timetable of a metro line | swagger (sw_transit.json:866) | docs-only [official swagger] |
| GET | `/linies/bus` | All bus lines; geometry `MultiLineString` | swagger (sw_transit.json:367); live capture `tests/fixtures/bus_lines.meta.json:6` | seen-in-working-code |
| GET | `/linies/bus/{codi_linia}` | Single bus line | aalises `src/datasources/BusDataSource.ts:148`; transit intro code-filter example `.../linies/bus/109` | docs-only [official swagger, intro] |
| GET | `/linies/bus/{codi_linia}/recs` | Bus route records, both directions, with full polyline geometry | swagger (sw_transit.json:587); live captures `tests/fixtures/bus_routes.meta.json:6` and `bus_routes_projected.meta.json:6`; pytmb `src/pytmb/transit.py:29` | seen-in-working-code |
| GET | `/linies/bus/{codi_linia}/recs/cons` | Consolidated bus routes (merged per direction) | swagger (sw_transit.json:614); live capture `tests/fixtures/bus_routes_consolidated.meta.json:6`; pytmb `src/pytmb/transit.py:37` | seen-in-working-code |
| GET | `/linies/bus/{codi_linia}/recs/reals` | "Real" bus route records | swagger (sw_transit.json:641) | docs-only [official swagger] |
| GET | `/linies/bus/{codi_linia}/parades` | Stops of one bus line, with `ID_SENTIT`, `ORDRE`, `DISTANCIA_PAR_ANTERIOR` | swagger (sw_transit.json:447); live capture `tests/fixtures/bus_stops_discovery.meta.json:6`; xavivg91 `R/bus.stops.R:62`; alemuro `tmb/__init__.py:74` | seen-in-working-code |
| GET | `/linies/bus/{codi_linia}/parades/cons` | Consolidated stops of a bus line | swagger (sw_transit.json:474) | docs-only [official swagger] |
| GET | `/linies/bus/{codi_linia}/parades/reals` | Real stops of a bus line | swagger (sw_transit.json:501) | docs-only [official swagger] |
| GET | `/linies/bus/{codi_linia}/horaris` | General timetable of a bus line | swagger (sw_transit.json:420) | docs-only [official swagger] |
| GET | `/linies/bus/{codi_linia}/parades/{codi_parada}/horaris` | Timetable of one stop on one bus line | swagger (sw_transit.json:527) | docs-only [official swagger] |
| GET | `/linies/bus/{codi_linia}/parades/{codi_parada}/horespas` | Passing times per stop from the line timetable | swagger (sw_transit.json:557) | docs-only [official swagger] |
| GET | `/linies/bus/{codi_linia_base}/parades/{codi_parada}/corresp` | Correspondences of the stops of a bus line | swagger (sw_transit.json:390) | docs-only [official swagger] |
| GET | `/linies` | All transport lines | swagger (sw_transit.json:325) | docs-only [official swagger] |
| GET | `/linies/altres` | Lines of other operators | swagger (sw_transit.json:346) | docs-only [official swagger] |
| GET | `/parades` | All bus stops (Point geometry, `CODI_PARADA`, `NOM_PARADA`, address, district) | swagger (sw_transit.json:968); alemuro `tmb/__init__.py:72`; aalises `src/datasources/BusDataSource.ts:123` | docs-only [official swagger] + third-party code (no capture) |
| GET | `/parades/{codi_parada}` | One bus stop | aalises `src/datasources/BusDataSource.ts:68`; transit intro example `.../parades/2775` | docs-only [official swagger, intro] |
| GET | `/parades/{codi_parada}/corresp` | Correspondences of a bus stop | swagger (sw_transit.json:990) | docs-only [official swagger] |
| GET | `/parades/{codi_parada}/mobiliari` | Street furniture at a bus stop | swagger (sw_transit.json:1017) | docs-only [official swagger] |
| GET | `/mobiliari` | All stop furniture | swagger (sw_transit.json:946) | docs-only [official swagger] |
| GET | `/estacions` | Metro stations, grouped (`CODI_GRUP_ESTACIO`, `PICTO`) | swagger (sw_transit.json:119); aalises `src/datasources/MetroDataSource.ts:96` | docs-only [official swagger] |
| GET | `/estacions/{codi_grup_estacio}/accessos` | Accesses of a metro station group | swagger (sw_transit.json:141) | docs-only [official swagger] |
| GET | `/estacions/{codi_grup_estacio}/accessos/{codi_acces}/corresp` | Correspondences of one access | swagger (sw_transit.json:168) | docs-only [official swagger] |
| GET | `/estacions/{codi_grup_estacio}/accessos/{codi_acces}/fisics` | Physical accesses of one access | swagger (sw_transit.json:198) | docs-only [official swagger] |
| GET | `/interc` | Bus interchanges | swagger (sw_transit.json:228) | docs-only [official swagger] |
| GET | `/interc/{codi_interc}/corresp` | Correspondences of an interchange | swagger (sw_transit.json:250) | docs-only [official swagger] |
| GET | `/interc/{codi_interc}/parades` | Stops of an interchange | swagger (sw_transit.json:277) | docs-only [official swagger] |
| GET | `/elements/superficie/{lon}/{lat}/{dist}` | Surface transit elements near a point (radius search) | swagger (sw_transit.json:52) | docs-only [official swagger] |
| GET | `/elements/superficie/{tipus}/{lon}/{lat}/{dist}` | Same, filtered by type (1 stations, 2 stops, 3 accesses, 4 interchanges) | swagger (sw_transit.json:84) | docs-only [official swagger] |
| GET | `/elements/superficie/corresp/{lon}/{lat}/{dist}` | Near-point search including correspondences | swagger (sw_transit.json:20) | docs-only [official swagger] |
| GET | `/limits/municipis` | Municipal boundary geometries | swagger (sw_transit.json:304) | docs-only [official swagger] |

Note on the geo surface: response `crs` is `urn:ogc:def:crs:EPSG::4326` by default; `srsName=EPSG:25831` switches to projected metres (verified for `/linies/bus/23/recs` in `tests/fixtures/bus_routes_projected.meta.json:6`).

---

## ibus (current) — `basePath: /v1/itransit`

Swagger: `https://developer.tmb.cat/assets/api-docs/v1/ibus/swagger.json`. This is the **replacement** for the legacy iBus service; the spec says the old one is deprecated and will disappear.

| Method | Path | Returns | Source | Confidence |
| --- | --- | --- | --- | --- |
| GET | `/itransit/bus/parades/{codi_parada}` | Next arrivals for every line/trip serving a stop: `timestamp` + `parades[]` with `linies_trajectes[]` (`codi_linia`, `nom_linia`, `id_sentit`, `codi_trajecte`, `desti_trajecte`, `transit_namespace` = `bus`\|`amb`, `propers_busos[]` with `temps_arribada` epoch-ms and nullable `id_bus`) | swagger `paths./bus/parades/{codi_parada}` (sw_ibus.json:20); live captures `tests/fixtures/bus_eta.meta.json:6`, `bus_eta_operating.meta.json:6`, `bus_eta_empty.meta.json:6`; pytmb `src/pytmb/bus.py:14`; ibus-mcp `src/server.ts:29` (`https://api.tmb.cat/v1/itransit/bus/parades`) and `:151`; medusero `src/tmbApi.ts:11` | seen-in-working-code |

---

## ibus_legacy (deprecated) — `basePath: /v1/ibus`

Swagger: `https://developer.tmb.cat/assets/api-docs/v1/ibus_legacy/swagger.json`. Still served; spec marks it as scheduled for removal.

| Method | Path | Returns | Source | Confidence |
| --- | --- | --- | --- | --- |
| GET | `/ibus/stops/{codi_parada}` | Array of `{routeId, line, text-ca, t-in-s, t-in-min}`; optional `numberOfPredictions` (default 1) | swagger `paths./stops/{codi_parada}` (sw_ibus_legacy.json:20); alemuro `tmb/__init__.py:24` with live unit tests at `tmb/__init__.py:162-183` | seen-in-working-code |
| GET | `/ibus/lines/{codi_linia}/stops/{codi_parada}` | Same shape, filtered to one line; optional `numberOfPredictions` | swagger `paths./lines/{codi_linia}/stops/{codi_parada}` (sw_ibus_legacy.json:52); alemuro `tmb/__init__.py:26` + test `:162` (stop 366, line V21) | seen-in-working-code |

Home Assistant's `tmb` integration is built on this legacy surface: `homeassistant/components/tmb/manifest.json` pins `tmb==0.0.4`, and `homeassistant/components/tmb/sensor.py:60` instantiates `IBus(app_id, app_key)` — i.e. HA consumes only `ibus/stops/{stop}` and `ibus/lines/{line}/stops/{stop}`.

---

## imetro — `basePath: /v1/itransit`

Swagger: `https://developer.tmb.cat/assets/api-docs/v1/imetro/swagger.json`.

| Method | Path | Returns | Source | Confidence |
| --- | --- | --- | --- | --- |
| GET | `/itransit/metro/estacions?estacions={codes}` | Next train arrivals per station: `timestamp` + `linies[]` → `estacions[]` (`codi_estacio`, `codi_via`, `id_sentit`) → `linies_trajectes[]` (`codi_trajecte`, `desti_trajecte`) → `propers_trens[]` (`codi_servei`, `temps_arribada` epoch-ms). `estacions` is a **required comma-separated list** | swagger `paths./metro/estacions` (sw_imetro.json:20); live captures `tests/fixtures/metro_eta.meta.json:6`, `metro_eta_running.meta.json:6`, `metro_eta_empty.meta.json:6`; pytmb `src/pytmb/metro.py:13-15`; Mapaor/metro-ara `src/app/api/arrivals/route.ts:3` | seen-in-working-code |

---

## planner — `basePath: /v1/planner`

Swagger: `https://developer.tmb.cat/assets/api-docs/v1/planner/swagger.json`. Backed by OpenTripPlanner.

| Method | Path | Returns | Source | Confidence |
| --- | --- | --- | --- | --- |
| GET | `/planner/plan` | OTP plan: `plan.itineraries[].legs[]` with `mode`, `route`, `from`/`to` places, `legGeometry`, `steps`, intermediate stops; itinerary metrics `duration`, `transitTime`, `waitingTime`, `walkDistance`, `transfers` | swagger `paths./plan` (sw_planner.json:21); live captures `tests/fixtures/planner_transit.meta.json:6`, `planner_walk.meta.json:6`, `planner_empty.meta.json:6`, `planner_invalid_mode.meta.json:6` (HTTP 500 for bad `mode`); pytmb `src/pytmb/planner.py:86`; alemuro `tmb/__init__.py:121` | seen-in-working-code |

Required query params: `fromPlace` (`lat,lon`), `toPlace`, `date` (`MM-DD-YYYY`), `time` (`hh:mmam|pm`), `arriveBy`, `mode` (`TRANSIT,WALK` …). Optional: `maxWalkDistance`, `showIntermediateStops`.

---

## static — `basePath: /v1/static/datasets`

Swagger: `https://developer.tmb.cat/assets/api-docs/v1/static/swagger.json` (only one path).

| Method | Path | Returns | Source | Confidence |
| --- | --- | --- | --- | --- |
| GET | `/static/datasets/gtfs.zip` | ZIP of the TMB GTFS feed (`produces: application/zip`) | swagger `paths./gtfs.zip` (sw_static.json:17) and `info.description` | docs-only [official swagger] — not downloaded here (needs credentials) |

The spec does not enumerate the archive members. `shapes.txt` presence is **standard-GTFS inference, not observed**: tag `guess`.

---

## alerts

No public Swagger asset exists at `/assets/api-docs/v1/alerts/swagger.json` (302 → `auth.tmb.cat`), and no endpoint path appears in any source reviewed. `AlejandroPico/TMB/docs/api-catalog.json` — which scraped the official specs and lists 40 transit paths — has **no** `alerts` key at all, and `docs/directo.md:19` states the reviewed catalogue contains no real-time metro positions or alert API, only that a specific access would have to be confirmed with TMB.

Conclusion: **no verified `/v1/alerts` (or equivalent) endpoint exists in the public surface.** Common public knowledge of a "TMB alerts/incidències" API is unverified; do not code against one.

---

## Adjacent data (not TMB API, but relevant to the geometry question)

- AMB GTFS-RT bus trip updates (excludes TMB-operated buses): `https://www.amb.cat/.../servei-gtfs-real-time-autobusos/6332347/11692` — documented in `AlejandroPico/TMB/docs/directo.md:20,45`.
- AlejandroPico/TMB reconstructs missing shapes from IGN/INSPIRE `api-features.idee.es/collections/railwaylink` (`docs/README.md:79`), which is a workaround for exactly the geometry gap discussed below.

---

## Metro line geometry candidates

Ranked best first. Everything is scoped to "give me the polyline of metro line N".

### 1. `GET /v1/transit/linies/metro` — **confirmed, use this**

- Evidence: live HTTP 200 capture in `apikurt/pytmb` (`tests/fixtures/metro_lines.json`, provenance `tests/fixtures/metro_lines.meta.json:6`, captured 2026-10-16, `query: {filter: "CODI_LINIA=1", srsName: "EPSG:4326"}`).
- Payload: `FeatureCollection` whose single feature for L1 has `geometry.type = "MultiLineString"` with one member of **105 positions**, from `[2.09846443, 41.34213332]` (Hospital de Bellvitge) to `[2.22100785, 41.45253315]` (Fondo) — a genuine, simplified full-line path in `EPSG:4326` (`crs.name = urn:ogc:def:crs:EPSG::4326`).
- Whole-network proof: `tests/fixtures/README.md` — *"the complete unfiltered catalogues … 114 bus lines and 11 metro lines, all with `MultiLineString` geometry"*.
- Variants: `?filter=CODI_LINIA=1` (server-side, observed) or `/linies/metro/1`; `srsName=EPSG:25831` for projected metres (proven only for bus `recs`, so treat as likely-but-unverified here).
- Cost: one request returns all 11 lines with geometry, no per-line loop.
- Caveat: 105 points is a cartographic simplification, not survey grade, and it does not encode per-direction paths.

### 2. `GET /v1/transit/linies/metro/{codi_linia}/recs` — documented, unverified shape

- `swagger.json` → `/linies/metro/{codi_linia}/recs` (sw_transit.json:893), summary *"Informació recorreguts de metro"*, description *"Recorreguts d'una línia de Metro (anada i tornada), donat el seu codi"*, response `LlistaRecorregutsMetro` → `RecorregutMetro` = `allOf[FeatureBase, …]` with `CODI_LINIA`, `CODI_SENTIT` (`A`), `ID_REC_LINIA`, `ID_SENTIT`, `ORIGEN_SENTIT`/`DESTI_SENTIT`.
- Why it ranks second: it is the metro analogue of `/linies/bus/{code}/recs`, which **is** confirmed to carry full polylines (see bus captures), and it separates directions — the one thing `/linies/metro` does not give you. But `FeatureBase.geometry` in the spec is a generic object with `x-example: Point` and the actual geometry type is not stated, so the polyline claim is unverified.
- Action if you need per-direction geometry: spend one authenticated call on it. It is the likely replacement for `/trams`.

### 3. `GET /v1/static/datasets/gtfs.zip` → `shapes.txt` — documented file, inferred contents

- The endpoint itself is documented (`sw_static.json:17`). GTFS `shapes.txt` + `trips.txt`/`routes.txt` is the canonical way to get exact, per-trip, per-direction metro polylines including tunnels.
- Unverified: that the TMB feed ships `shapes.txt` at all. This is the one candidate that could be definitive and is worth checking first with credentials, because a `shapes.txt` absence explains every other gap here.

### 4. `GET /v1/transit/linies/metro/{codi_linia}/trams` — documented but dead

- Documented at sw_transit.json:919 as *"Trams entre estacions de Metro"*, response `TramMetro` with `CODI_ESTACIO_INI/FI`, `LONGITUD`, `ORDRE_TRAM`, `ID_TRAM_LINIA`.
- Your probe returned **HTTP 404**, and the schema's own `geometry` is unspecified; `LONGITUD` is a length attribute, not a path. So even if it worked, it is segment metadata, not a line polyline.

### 5. `GET /v1/transit/linies/metro/{codi_linia}/estacions` — points only, never line geometry

- Confirmed 200 by your probe and by `tests/fixtures/metro_stations_discovery.meta.json:6`. Each feature is a station **Point** with `CODI_ESTACIO`, `NOM_ESTACIO`, `ORDRE_ESTACIO`, `PICTO`, `DATA_INAUGURACIO`.
- Useful only to *derive* a coarse polyline by ordering `ORDRE_ESTACIO` and joining consecutive points — which is what a station-sequence rendering needs, but it is not the track.

### 6. `GET /v1/transit/linies/metro/{codi_linia}/estacions/central` — worst option

- Documented (sw_transit.json:717) as the same station list with central-point geometry. Still Points. No reason to prefer it over #5.

### Recommendation

Use **#1** now (`GET /v1/transit/linies/metro?filter=CODI_LINIA={n}`) — it is the only metro-polyline path with live evidence, it is one request, and it already answers your 404/200 puzzle: `/trams` is the wrong branch of the tree; the geometry was on the parent collection all along. Then check **#3** (`shapes.txt`) with credentials if you need per-direction or tunnel-accurate geometry, and **#2** (`/recs`) if you need direction-split polylines without the GTFS download.
