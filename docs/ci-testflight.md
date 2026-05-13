# iOS TestFlight CI

GitHub Actions workflow that builds Deadwax Club and uploads to TestFlight on
every push to `main` that touches the iOS app sources (also runnable on demand
via the Actions tab).

The workflow lives at [`.github/workflows/ios-testflight.yml`](../.github/workflows/ios-testflight.yml).

## One-time setup

### 1. App Store Connect API key

1. https://appstoreconnect.apple.com → Users and Access → Integrations → App
   Store Connect API → **Generate API Key**
2. Access: `App Manager` (minimum required to upload builds)
3. Download the `.p8` file — **you only get one chance to download it**
4. Note down:
   - **Issuer ID** (UUID, top of the keys page)
   - **Key ID** (10 chars, on the key row)

### 2. Apple Team ID

https://developer.apple.com → top-right corner. 10-character alphanumeric.

### 3. Set GitHub secrets

Repo → Settings → Secrets and variables → Actions → New repository secret:

| Secret name | Value |
|---|---|
| `APP_STORE_CONNECT_API_KEY_P8` | Full contents of the `AuthKey_XXXXXXXXXX.p8` file (including `BEGIN`/`END` lines) |
| `APP_STORE_CONNECT_API_KEY_ID` | 10-char Key ID |
| `APP_STORE_CONNECT_API_KEY_ISSUER_ID` | UUID Issuer ID |
| `APPLE_TEAM_ID` | 10-char team ID |
| `IOS_SECRETS_XCCONFIG` | Full contents of `Config/Secrets.xcconfig` (the file is git-ignored locally; paste the whole thing here including the `//` value-quoting hack noted in `CLAUDE.md`) |

### 4. First run

Trigger manually first to shake out signing:

Repo → Actions → **iOS · TestFlight** → Run workflow → choose `main`.

Watch the **Archive** step closely on the first run — `-allowProvisioningUpdates`
combined with the API key tells Xcode to auto-create / refresh the App ID and
provisioning profile in App Store Connect. If you've never built this app in
App Store Connect before, the first archive will create everything; subsequent
runs reuse it.

Once the first manual run succeeds and a build lands in TestFlight, future
pushes to `main` that touch the iOS source will trigger uploads automatically.

## What the workflow does

1. Checks out `main`
2. Selects Xcode 16 (falls back to runner default if unavailable)
3. Installs `xcodegen` via Homebrew
4. Writes `Config/Secrets.xcconfig` from the `IOS_SECRETS_XCCONFIG` secret
5. Drops the API key `.p8` into `~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8`
6. Stamps `CURRENT_PROJECT_VERSION` in `project.yml` with the GitHub run number
   so TestFlight gets a unique build number each upload
7. Stamps `DEVELOPMENT_TEAM` in `project.yml` from `APPLE_TEAM_ID`
8. Runs `xcodegen generate` to build `DeadWaxClub.xcodeproj`
9. Resolves Swift packages
10. `xcodebuild archive` with cloud-managed signing via the API key
11. `xcodebuild -exportArchive` into an `.ipa`
12. `xcrun altool --upload-app` to TestFlight

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
- **Adding a new Supabase / Discogs / Sentry secret to `Secrets.xcconfig`**:
  add the line locally, copy the full file contents, paste into the
  `IOS_SECRETS_XCCONFIG` secret. Also bump `Config/Secrets.xcconfig.example`
  so future contributors see the new key.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `error: No profiles for 'com.deadwaxclub.app' were found` on Archive | API key lacks App Manager access, or the App ID isn't registered. Run `-allowProvisioningUpdates` (already on) should auto-create, but the API key role matters. |
| `error: Bundle identifier is missing` | `PRODUCT_BUNDLE_IDENTIFIER` not making it through xcodegen — check `project.yml`. |
| Upload step says "Redundant Binary Upload" | TestFlight already has a build with that `CFBundleVersion`. Re-run the workflow — `GITHUB_RUN_NUMBER` will bump. |
| `Cannot find module 'Sentry'` (or any SPM module) | Package resolution step failed. Check the resolve step's log; usually a transient network issue with `github.com`. |
| `xcodebuild` hangs on signing | API key not in `~/.appstoreconnect/private_keys/AuthKey_*.p8`. Inspect the "Write App Store Connect API key" step. |
