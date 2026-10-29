# TransportCat — iOS nativo clon de andana.bcn.am

App iOS nativa (SwiftUI) que replica andana.bcn.am: metro de Barcelona en tiempo real
(mapa con trenes, diagrama de línea, estaciones, afectaciones), con datos directos de la
API pública de TMB y despliegue a TestFlight con la pipeline del skill ios-testflight-pipeline.

## Specs

- S1: "cloname esto en una app para IOS SWIFT native ultima version" — app nativa
  SwiftUI, Xcode 26 / SDK iOS 26 vía runner `macos-26` (igual que Drivy), deployment
  target iOS 17.0, XcodeGen (`project.yml`), `.xcodeproj` nunca commiteado.
  Identidad: repo `albert-castellvi/TransportCat`, bundle `cat.transport.app`,
  nombre de producto "TransportCat".
- S2: clonar andana: mapa en vivo con posición de trenes, diagrama interactivo de cada
  línea, detalle de estación con próximas llegadas, estado del servicio (afectaciones).
  EXCLUIDO (explícito: "no hay pagos" y admin/beta son de la web): pagos/StoreKit,
  autenticación, zona admin/beta, anuncios, telemetría avanzada, juego trainspotter.
- S3: "no tengo claro que sea necesario usar supabase" → NO hay Supabase ni backend
  propio. Datos directos de la API pública de TMB (`https://api.tmb.cat/v1`) con
  app_id/app_key propios del usuario, inyectados en build (GitHub secrets → xcconfig
  generado en el runner); JAMÁS commiteados. Decisión de fuente confirmada por el
  usuario: "API pública de TMB directa" (no la API de andana).
- S4: "usa el skill (puede clonar incluso la pipeline usada en Drivy) para poder
  desplegar a testdrive [TestFlight]" — pipeline del skill ios-testflight-pipeline
  clonada de `albert-castellvi/drivy`: job `test` en PR (simulador, sin team), job
  firmado en `main` (entorno `release`, secrets ASC, `provision-signing.sh`,
  dSYMs a Sentry). Sin Sign in with Apple (no aplica). Pasos manuales siempre al
  humano; nunca inventar team id / key id / issuer id. Team público de Drivy:
  QP5A6D4Y4P (reutilizable).
- S5: UI de la app en catalán (idioma de la web, `lang="ca"`).
- S6: Posiciones de tren calculadas EN CLIENTE: para cada llegada iBus (estación i,
  dirección D) el tren se posiciona entre la estación i-1 e i con progreso
  secToArrival/duraciónEstimada; duración estimada proporcional a la distancia sobre
  la geometría de la línea (tram GeoJSON). Motor determinista y testeado con
  fixtures. Líneas (CODI_LINIA, claves de la red de andana): 1,2,3,4,5,11,9N,9S,
  10N,10S,FM. Endpoints: `/transit/linies/metro/{CODI}/estacions` (GeoJSON),
  `/transit/linies/metro/{CODI}/tram` (GeoJSON), `/ibus/lines/{CODI}/stops/{PARADA}`,
  `/alerts/metro/channels/WEB`. Decoders tolerantes; validar formas reales contra la
  API en vivo cuando existan las claves (verificación pendiente de claves TMB).

## Tasks

- T1 [S1] scaffold: `project.yml`, Info.plist, entry SwiftUI, assets, .gitignore,
  estructura de carpetas, README stub. Route: worker (GPT, effort medium). Commit:
  pendiente.
- T2 [S3,S6] cliente TMB: modelos, decoders tolerantes, TMBClient (async/await),
  fixtures + tests con URLProtocol mock. Route: worker (GPT, effort medium). Commit:
  pendiente.
- T3 [S6] motor de posiciones: interpolación iBus→lat/lng sobre geometría, tests
  deterministas (RED→GREEN en CI). Route: worker (GPT, effort medium). Commit:
  pendiente.
- T4 [S2,S5] UI: mapa (MapKit) con overlay de línea y trenes, diagrama de línea
  (Canvas), detalle de estación (llegadas iBus), banner/lista de afectaciones;
  polling ~15s visible; catalán. Route: worker (GPT, effort medium). Commit: pendiente.
- T5 [S4] pipeline: ci.yml (test+release), provision-signing.sh sin SIWA, Sentry,
  ITSAppUsesNonExemptEncryption, inyección TMB_APP_ID/TMB_APP_KEY por secret,
  README con checklist manual. Route: worker (GPT, effort medium). Commit: pendiente.
- T6 [S1..S4] verificación: CI verde en la rama (requiere push — decisión del
  usuario) + handoff del checklist manual al humano. Route: orquestador + verify.
  Commit: n/a.

## Log

- L1 (petición original, verbatim): "https://andana.bcn.am/ cloname esto en una app
  para IOS SWIFT native ultima version aqui te dejo el repo, y usa el skill (puede
  clonar incluso la pipeline usada en Drivy) para poder desplegar a testdrive, en
  este caso, no hay pagos y no tengo claro que sea necesario usar supabase" +
  "Encargate tu de revisarlo, en este caso si te hace falta usa GPT sol en medium
  como mucho para no comerte los tokens como caramelos" + "gh repo clone
  albert-castellvi/TransportCat".
- L2 (decisiones del usuario por ask_user_question): fuente de datos = "API pública
  de TMB directa"; identidad = "TransportCat / cat.transport.app"; Sentry = "Sí, con
  Sentry".
- L3 (descubrimiento): andana es React+Cloudflare Pages con backend propio
  (`/api/metro/*` incluye `/trains/all` y SSE `/events`); sus posiciones de tren se
  computan en servidor. Al elegir TMB directa, ese cómputo pasa al cliente (S6).
  Los endpooints TMB usados por andana: `api.tmb.cat/v1/alerts/metro/channels/WEB`
  (llamada directa desde el cliente con sus claves embebidas).
- L4 (restricción de entorno): la máquina local es Linux sin Xcode → compilación y
  tests solo verificables en CI (runner macos-26). Los workers no pueden ejecutar
  XCTest localmente; escriben código+tests y la verificación real es el job `test`
  de CI tras push.
