# TransportCat

Native iOS client for the Barcelona metro in real time, built with SwiftUI.
Network topology and live arrivals come straight from the public TMB API
([developer.tmb.cat](https://developer.tmb.cat)); train positions are computed
on device by interpolating live metro arrivals (i-Metro) over each line's
geometry. No backend of our own. Distributed via TestFlight through GitHub
Actions (XcodeGen, no committed `.xcodeproj`).

## Manual checklist (one human, in order)

Everything below is a human action; the pipeline never guesses a value.
Secrets live only in GitHub → Settings → Environments → `release` →
Environment secrets.

1. **Apple Developer**: confirm the Team ID (`QP5A6D4Y4P`, already wired into
   `ci.yml`). Decide whether to reuse the existing Apple Distribution
   certificate (Drivy's `.p12`) or revoke it and let CI mint a new one.
2. **App Store Connect — app record**: Apps → New App, iOS, main language
   Catalan, bundle id `cat.transport.app` (must match `project.yml`
   character for character). Create it before the first push to `main`.
3. **App Store Connect — API key**: Users and Access → Integrations → new key,
   role App Manager. Copy Issuer ID and Key ID; download `AuthKey_<KEYID>.p8`
   (once).
4. **GitHub**: create environment `release` with deployment rule `main` only,
   then the environment secrets:
   - `APP_STORE_CONNECT_API_ISSUER_ID`
   - `APP_STORE_CONNECT_API_KEY_ID`
   - `APP_STORE_CONNECT_API_KEY_BASE64` (the `.p8`, base64 or raw PEM)
   - `DIST_CERTIFICATE_P12_BASE64` and `DIST_CERTIFICATE_PASSWORD`
     (only if reusing the existing distribution certificate)
   - `TMB_APP_ID` and `TMB_APP_KEY` (free registration at
     developer.tmb.cat)
   - `SENTRY_DSN` (Sentry iOS project) and `SENTRY_AUTH_TOKEN` (org token,
     enables dSYM upload)
   The Sentry project slug must be `transportcat` in org `acr-studio`
   (dSYM upload step), or adjust `.github/workflows/ci.yml`.
5. **Sentry**: create project `transportcat` (platform Apple/iOS) and the auth
   token before the first tester; without the token the build still uploads,
   but Release crashes arrive unsymbolicated.
6. **First run**: open a PR — only the `test` job runs (no Apple account
   needed). When green, merge to `main`: the signed job archives, uploads to
   TestFlight and pushes dSYMs to Sentry. Use `[skip ci]` in the merge
   subject for documentation-only merges.
7. **TestFlight**: create a tester group, fill "What to Test". Export
   compliance is declared in Info.plist
   (`ITSAppUsesNonExemptEncryption=false`), so no per-build questionnaire.
8. **App icon**: the asset catalog currently has an empty AppIcon set. Add a
   real 1024×1024 icon before distributing to testers.

Local build for development: create `Support/secrets.xcconfig`-style values
via `xcodegen generate` and pass
`TMB_APP_ID=<id> TMB_APP_KEY=<key>` to `xcodebuild` (or set them in Xcode).
