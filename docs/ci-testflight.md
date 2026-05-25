# iOS TestFlight CI

GitHub Actions workflow that builds Deadwax Club and uploads to TestFlight on
every push to `main` that touches the iOS app sources (also runnable on demand
via the Actions tab).

The workflow lives at [`.github/workflows/ios-testflight.yml`](../.github/workflows/ios-testflight.yml).

## One-time setup

### 1. App Store Connect API key

1. https://appstoreconnect.apple.com → Users and Access → Integrations → App
   Store Connect API → **Generate API Key**
2. Access: `App Manager` (used by CI to upload builds)
3. Download the `.p8` file — **you only get one chance to download it**
4. Note down:
   - **Issuer ID** (UUID, top of the keys page)
   - **Key ID** (10 chars, on the key row)

### 2. Apple Team ID

https://developer.apple.com → top-right corner. 10-character alphanumeric.

### 3. Signing identifiers and capabilities

The app ships with a WidgetKit extension, so CI must be able to provision both
bundle IDs:

| Target | Bundle ID |
|---|---|
| App | `com.deadwaxclub.app` |
| Widgets extension | `com.deadwaxclub.app.widgets` |

Both targets also use the App Group `group.com.deadwaxclub.app`.

Before the first CI archive after adding or changing widgets, verify in Apple
Developer Certificates, Identifiers & Profiles that:

1. Both bundle IDs exist on the same team as `APPLE_TEAM_ID`.
2. The App Groups capability is enabled on both bundle IDs.
3. `group.com.deadwaxclub.app` exists and is assigned to both bundle IDs.
4. App Store provisioning profiles exist with these exact names:
   - `DeadwaxClub App Store` for `com.deadwaxclub.app`
   - `DeadwaxClub Widgets App Store` for `com.deadwaxclub.app.widgets`

The workflow uses reusable manual signing assets, matching Diald's setup: a
shared Apple Distribution certificate plus per-bundle provisioning profiles.
If the checked-in profile names do not exactly match the Apple Developer
profile names, archive/export fails with `No profiles for ... were found`.

### 4. Set GitHub secrets

Repo → Settings → Secrets and variables → Actions → New repository secret:

| Secret name | Value |
|---|---|
| `APP_STORE_CONNECT_API_KEY_P8` | Full contents of the `AuthKey_XXXXXXXXXX.p8` file (including `BEGIN`/`END` lines) |
| `APP_STORE_CONNECT_API_KEY_ID` | 10-char Key ID |
| `APP_STORE_CONNECT_API_KEY_ISSUER_ID` | UUID Issuer ID |
| `APPLE_TEAM_ID` | 10-char team ID |
| `IOS_DISTRIBUTION_CERTIFICATE_BASE64` | Base64-encoded `.p12` Apple Distribution certificate; can be reused across apps on the same team |
| `IOS_DISTRIBUTION_CERTIFICATE_PASSWORD` | Password used when exporting the `.p12` certificate |
| `IOS_DEADWAXCLUB_PROFILE_BASE64` | Base64-encoded App Store provisioning profile named `DeadwaxClub App Store` |
| `IOS_DEADWAXCLUB_WIDGETS_PROFILE_BASE64` | Base64-encoded App Store provisioning profile named `DeadwaxClub Widgets App Store` |
| `IOS_KEYCHAIN_PASSWORD` | Temporary CI keychain password; any strong random value |
| `IOS_SECRETS_XCCONFIG` | Full contents of `Config/Secrets.xcconfig` (the file is git-ignored locally; paste the whole thing here including the `//` value-quoting hack noted in `CLAUDE.md`) |

### 5. First run

Trigger manually first to shake out signing:

Repo → Actions → **iOS · TestFlight** → Run workflow → choose `main`.

Watch the **Install signing certificate and profiles** and **Archive** steps
closely on the first run. CI does not create profiles automatically; it installs
the reusable `.p12` distribution certificate and the two uploaded
`.mobileprovision` files by their embedded UUIDs, then archives with manual
Release signing. The install step validates the embedded profile names before
archive so a wrong uploaded profile fails early.

Once the first manual run succeeds and a build lands in TestFlight, future
pushes to `main` that touch the iOS source will trigger uploads automatically.

## What the workflow does

1. Checks out `main`
2. Selects Xcode 16 (falls back to runner default if unavailable)
3. Installs `xcodegen` via Homebrew
4. Writes `Config/Secrets.xcconfig` from the `IOS_SECRETS_XCCONFIG` secret
5. Drops the API key `.p8` into `~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8`
6. Installs the Apple Distribution certificate and App Store provisioning profiles
   into a temporary CI keychain/profile directory
7. Stamps `CURRENT_PROJECT_VERSION` in `project.yml` with the GitHub run number
   so TestFlight gets a unique build number each upload
8. Stamps `DEVELOPMENT_TEAM` in `project.yml` from `APPLE_TEAM_ID`
9. Runs `xcodegen generate` to build `DeadWaxClub.xcodeproj`
10. Resolves Swift packages
11. `xcodebuild archive` with manual Release signing
12. `xcodebuild -exportArchive` into an `.ipa`
13. `xcrun altool --upload-app` to TestFlight

On failure, the partial archive is uploaded as a workflow artifact for 7 days.

## Costs

`macos-15` runners use a **10× multiplier** against your GitHub Actions minute
budget. A full archive + upload typically takes 10–15 wall-clock minutes →
100–150 minutes drawn from the budget per run. On the free tier (2,000
minutes/month), that's roughly 13–20 builds before paid usage kicks in.

Path filters keep us off the runner for web-only / Supabase-only / docs-only
changes.

## Maintenance

- **Bumping marketing version**: edit `MARKETING_VERSION` in `project.yml`
  (`0.1.0` → `0.2.0` etc.). CI keeps stamping `CURRENT_PROJECT_VERSION` from
  the run number so build numbers stay monotonically increasing across version
  bumps.
- **Rotating the API key**: regenerate in App Store Connect, update the three
  `APP_STORE_CONNECT_API_KEY_*` secrets, no workflow change needed.
- **Rotating the distribution certificate or profiles**: export a new `.p12`
  and/or download fresh `.mobileprovision` files, base64-encode them, then
  update the corresponding `IOS_*_BASE64` secrets. Keep the provisioning profile
  display names as `DeadwaxClub App Store` and `DeadwaxClub Widgets App Store`
  unless you also update `project.yml` and `Scripts/ci/ExportOptions.plist`.
- **Adding a new Supabase / Discogs / Sentry secret to `Secrets.xcconfig`**:
  add the line locally, copy the full file contents, paste into the
  `IOS_SECRETS_XCCONFIG` secret. Also bump `Config/Secrets.xcconfig.example`
  so future contributors see the new key.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `Authentication failed: Make sure a bearer token was provided...` on Upload | The App Store Connect API key secrets are invalid. Check `APP_STORE_CONNECT_API_KEY_P8`, `APP_STORE_CONNECT_API_KEY_ID`, `APP_STORE_CONNECT_API_KEY_ISSUER_ID`, and that the key has App Manager access. |
| `IOS_DISTRIBUTION_CERTIFICATE_BASE64 is empty` or similar | The reusable signing secret has not been added to GitHub Actions secrets, or the secret name does not match the workflow. |
| `Expected provisioning profile ... but secret contains ...` | The secret contains a different `.mobileprovision` than the profile expected by `project.yml` and `ExportOptions.plist`. Upload the DeadWaxClub profile or update the checked-in profile name consistently. |
| `No profiles for 'com.deadwaxclub.app.widgets' were found` on Archive | The widget profile secret is missing/invalid, the profile is not named `DeadwaxClub Widgets App Store`, or the profile does not include the App Group entitlement. |
| `No profiles for 'com.deadwaxclub.app' were found` on Archive after adding widgets | The app profile secret is missing/invalid, the profile is not named `DeadwaxClub App Store`, or the app's profile does not include the App Group entitlement. |
| `error: Bundle identifier is missing` | `PRODUCT_BUNDLE_IDENTIFIER` not making it through xcodegen — check `project.yml`. |
| Upload step says "Redundant Binary Upload" | TestFlight already has a build with that `CFBundleVersion`. Re-run the workflow — `GITHUB_RUN_NUMBER` will bump. |
| `Cannot find module 'Sentry'` (or any SPM module) | Package resolution step failed. Check the resolve step's log; usually a transient network issue with `github.com`. |
| `xcodebuild` hangs on signing | API key not in `~/.appstoreconnect/private_keys/AuthKey_*.p8`. Inspect the "Write App Store Connect API key" step. |
