# Trackd

Native iOS app (SwiftUI, iOS 17+) for tracking the vinyl you own and the vinyl you want. Offline-first, syncs to Postgres, scans barcodes in shops, plots price changes over time.

## Features

- Email + password and Google sign-in (Supabase Auth)
- Offline-first SQLite mirrored to Supabase Postgres via PowerSync
- Owned / Wishlist tabs, manual entry, barcode scanning
- Discogs lookup for cover art, artist, year, colourway
- Price history per record with a Swift Charts line graph
- Cover art cached on device **and** mirrored to Supabase Storage so other devices fetch from your bucket instead of Discogs
- Light / Dark / System appearance toggle
- Error reporting via Sentry (optional)

## Stack

| Concern        | Tool                                                              |
| -------------- | ----------------------------------------------------------------- |
| UI             | SwiftUI, iOS 17+                                                  |
| Backend        | Supabase (Postgres + Auth + Storage)                              |
| Sync           | [PowerSync Swift SDK](https://github.com/powersync-ja/powersync-swift) |
| Auth           | `supabase-swift`                                                  |
| Metadata       | [Discogs API](https://www.discogs.com/developers)                 |
| Charts         | Swift Charts                                                      |
| Barcode        | VisionKit `DataScannerViewController`                             |
| Error logging  | `sentry-cocoa`                                                    |
| Project gen    | [XcodeGen](https://github.com/yonaskolb/XcodeGen)                 |

## First-time setup

### 1. Install tools

```sh
brew install xcodegen
```

### 2. Configure secrets

```sh
cp Config/Secrets.xcconfig.example Config/Secrets.xcconfig
```

Fill in:

- `SUPABASE_URL` and `SUPABASE_ANON_KEY` from your Supabase project settings.
- `POWERSYNC_URL` from the PowerSync dashboard once you've created an instance.
- `SENTRY_DSN` from a Sentry project (optional — leave blank to disable).

> xcconfig values that contain `//` must escape it as `/$()/` (already done in the example file).

### 3. Provision Supabase

In the Supabase SQL editor, run in order:

1. `Supabase/migrations/0001_init.sql` — tables, triggers, RLS policies.
2. `Supabase/migrations/0002_storage_covers.sql` — public `covers` bucket + policies.

Then in **Authentication → Providers**:
- Enable **Email**.
- Enable **Google**, paste a Google Cloud OAuth client ID + secret. In Google Cloud Console add the redirect URI Supabase shows you. Set the iOS callback to `trackd://auth-callback`.

### 4. Provision PowerSync

1. Create a free instance at <https://powersync.com>.
2. Connect it to your Supabase project (it walks you through it).
3. Apply the sync rules in `Supabase/powersync/sync_rules.yaml`.
4. Copy the instance URL into `POWERSYNC_URL` in `Secrets.xcconfig`.

### 5. Discogs token

In the running app, go to **Settings → Discogs API** and paste a personal access token from <https://www.discogs.com/settings/developers>. Stored in the keychain.

### 6. Generate the Xcode project

```sh
xcodegen generate
open Trackd.xcodeproj
```

`Trackd.xcodeproj` is git-ignored — regenerate it from `project.yml` whenever dependencies or sources change.

### 7. Build

```sh
xcodebuild build \
  -project Trackd.xcodeproj \
  -scheme Trackd \
  -destination 'platform=iOS Simulator,name=iPhone 15'
```

Or just hit ⌘R in Xcode.

## Repo layout

```
Trackd/
  App/         entry point, services container, secrets reader
  Auth/        AuthClient + sign-in / sign-up / Google flow
  Sync/        PowerSync schema, manager, status indicator
  Records/     list, detail, add, log price, repos
  Scanner/     VisionKit DataScanner wrapper, scan-result sheet
  Discogs/     barcode search + release fetch
  CoverArt/    on-device + Supabase Storage cache
  Models/      VinylRecord, PriceEntry, Profile
  Settings/    appearance, account, Discogs token
  Components/  Theme, PrimaryButton, Card, EmptyState, LoadingView
  Logging/     Sentry/OSLog wrapper, Keychain helper
  Resources/   Assets.xcassets

Supabase/
  migrations/  schema + storage policies
  powersync/   sync rules

Config/
  Secrets.xcconfig.example  template (real file is gitignored)
```

## Status

This is a first-cut scaffold. Everything is wired and the architecture is in place, but the app has not yet been built against a real Mac/Xcode toolchain — expect a small round of compile-time fixes when you run `xcodegen generate && open Trackd.xcodeproj` and hit ⌘B for the first time. The most likely places to need a tweak:

- **PowerSync Swift SDK** is in active development and the API names move between minor versions. `Trackd/Sync/DatabaseSchema.swift`, `PowerSyncManager.swift`, `SupabaseConnector.swift` and the repos in `Trackd/Records/` use names matching the documented 1.x API; if your installed version diverges, adjust call sites accordingly.
- **`supabase-swift` 2.x** OAuth helper names occasionally rename (`getOAuthSignInURL` vs `getOAuthURL` etc.). `Trackd/Auth/AuthClient.swift` is the only place that matters.
- **DataScannerViewController** requires running on a real device for camera; the simulator can't scan barcodes.

## Development notes

- `AppServices` constructs and owns all long-lived objects (`AuthClient`, `PowerSyncManager`, `DiscogsClient`, `CoverArtCache`, repositories). Views read them via `@EnvironmentObject`.
- Soft delete only: `records.deleted_at` is set instead of removing rows so PowerSync can sync the tombstone reliably.
- Cover art lookup order on display: local Caches file → Supabase Storage public URL → Discogs URL → SF Symbol placeholder. The first display of any record both writes the bytes to disk and uploads to Supabase Storage, so subsequent launches and other devices can render it without Discogs.
- `Trackd.xcodeproj` is regenerated from `project.yml`. Don't commit it.
