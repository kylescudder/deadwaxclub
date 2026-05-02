# Dead Wax Club

Native iOS app (SwiftUI, iOS 17+) for tracking the vinyl you own and the vinyl you want. Offline-first, syncs to Postgres, scans barcodes in shops, plots price changes over time, alerts you when a record on your wishlist drops to a new low, and lets you share lists with friends — privately, by link, or collaboratively.

## Features

- Email/password, Sign in with Apple, and Google sign-in (Supabase Auth)
- Offline-first SQLite mirrored to Supabase Postgres via PowerSync
- Owned / Wishlist tabs with sort + filter (year, colour way, has-price)
- Manual entry, barcode scanning, and Discogs lookup for cover art / artist / colour way
- Per-record price history with a Swift Charts line graph
- Discogs marketplace estimated value, clearly distinguished from prices you actually paid
- **Shareable lists** — private, public link, invite-only, or fully collaborative
- **Push notifications** when any wishlist record (yours or one a list-mate added) hits a new all-time low price
- **Stats** — total spent, collection value, breakdown by decade and colour way, top owned, lowest wishlist
- Cover art cached on device **and** mirrored to Supabase Storage so cover art works fully offline and other devices fetch from your bucket instead of Discogs
- **AppIntents + Spotlight** — find records from system search, "Hey Siri, log a price in Dead Wax Club"
- **Onboarding sheets** for display name, Discogs token, and notification permission
- Light / Dark / System appearance toggle
- Account deletion (App Store 5.1.1(v) compliant)
- Error reporting via Sentry (optional)

## Stack

| Concern        | Tool                                                              |
| -------------- | ----------------------------------------------------------------- |
| UI             | SwiftUI, iOS 17+                                                  |
| Backend        | Supabase (Postgres + Auth + Storage + Edge Functions)             |
| Sync           | [PowerSync Swift SDK](https://github.com/powersync-ja/powersync-swift) |
| Auth           | `supabase-swift` (email, Sign in with Apple, Google)              |
| Metadata       | [Discogs API](https://www.discogs.com/developers) (release + marketplace stats) |
| Charts         | Swift Charts                                                      |
| Barcode        | VisionKit `DataScannerViewController`                             |
| Push           | APNs via Supabase Edge Function (Deno)                            |
| Search         | CoreSpotlight + AppIntents                                        |
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

### 3. Provision Supabase

In the Supabase SQL editor, run in order:

1. `Supabase/migrations/0001_init.sql` — tables, triggers, RLS.
2. `Supabase/migrations/0002_storage_covers.sql` — public `covers` bucket.
3. `Supabase/migrations/0003_estimated_price.sql` — Discogs estimate columns.
4. `Supabase/migrations/0004_lists.sql` — lists, list_items, list_members + share-link RPCs.
5. `Supabase/migrations/0005_notifications.sql` — device tokens + new-low trigger.
6. `Supabase/migrations/0006_account_delete.sql` — `delete_my_account()` RPC.
7. `Supabase/migrations/0007_user_lookup.sql` — invite-by-email helper.

In **Authentication → Providers**:
- Enable **Email**.
- Enable **Apple** (paste a Services ID + key).
- Enable **Google** (Google Cloud OAuth client ID + secret).
- Set redirect URI to `deadwaxclub://auth-callback`.

### 4. Provision PowerSync

1. Create an instance at <https://powersync.com>.
2. Connect it to your Supabase project.
3. Apply `Supabase/powersync/sync_rules.yaml`.
4. Copy the instance URL into `POWERSYNC_URL` in `Secrets.xcconfig`.

### 5. Push notifications (optional but recommended)

For lowest-price alerts:

1. In the Apple Developer portal, create an APNs Auth Key (`.p8`).
2. In the Supabase dashboard, go to **Edge Functions → Secrets** and set:
   - `APNS_TEAM_ID` — your team ID
   - `APNS_KEY_ID` — the key's ID
   - `APNS_PRIVATE_KEY` — full contents of the `.p8` file (newlines preserved)
   - `APNS_BUNDLE_ID` — `com.deadwaxclub.app` (or your own)
3. Deploy the Edge Function:
   ```sh
   supabase functions deploy notify-price-change
   ```
4. In **Database → Webhooks**, create a webhook on `price_entries` `INSERT` events pointing at `https://<project>.supabase.co/functions/v1/notify-price-change`, with header `Authorization: Bearer <SUPABASE_ANON_KEY>`.

The function only sends when `is_new_low` is true (set by a `BEFORE INSERT` trigger), so you won't get spammed.

### 6. Public list web viewer (optional)

A small static site under `web/` renders public-link lists in any browser and serves the Universal Links manifest. Drop it onto Netlify (or any static host) at `deadwaxclub.app`:

```sh
cp web/js/config.example.js web/js/config.js
# Edit config.js with your Supabase URL + anon key
npx netlify deploy --dir=web --prod
```

Edit `web/.well-known/apple-app-site-association` and replace `TEAMID.com.deadwaxclub.app` with your real Apple Team ID + bundle. The `applinks:deadwaxclub.app` entry is already in `DeadWaxClub.entitlements`. After this is live, tapping any `https://deadwaxclub.app/l/<token>` link from another iOS app launches Dead Wax Club directly; if the app isn't installed, the recipient sees the web list.

See `web/README.md` for full deployment notes.

### 7. Discogs token

In the running app: **Settings → Discogs API**, paste a personal token from <https://www.discogs.com/settings/developers>. Stored in the keychain. The onboarding sheet prompts for this on first launch.

### 8. Generate the Xcode project

```sh
xcodegen generate
open DeadWaxClub.xcodeproj
```

`DeadWaxClub.xcodeproj` is git-ignored — regenerate from `project.yml` whenever dependencies or sources change.

In Xcode:
- Set your Development Team under **Signing & Capabilities**.
- Confirm the **Sign in with Apple**, **Push Notifications**, and **Associated Domains** capabilities are present (XcodeGen wires them via `DeadWaxClub.entitlements`).

### 9. Build

```sh
xcodebuild build \
  -project DeadWaxClub.xcodeproj \
  -scheme DeadWaxClub \
  -destination 'platform=iOS Simulator,name=iPhone 15'
```

Or hit ⌘R in Xcode. Barcode scanning needs a real device.

## Repo layout

```
DeadWaxClub/
  App/             entry point, services container, secrets, AppDelegate
  Auth/            AuthClient, sign-in views, Apple + Google flows
  Sync/            PowerSync schema, manager, status indicator
  Records/         list, detail, add, log price, sort, filter, repos
  Scanner/         VisionKit DataScanner + permission handling
  Discogs/         release + marketplace stats client
  CoverArt/        on-device + Supabase Storage cache
  Lists/           lists CRUD, share modes, public viewer
  Stats/           aggregates + Swift Charts
  Notifications/   APNs registration + token upload
  Onboarding/      first-run sheets
  Intents/         AppIntents, AppShortcuts, Spotlight indexing
  Models/          VinylRecord, PriceEntry, Profile, VinylList
  Settings/        appearance, account, Discogs token, push toggle
  Components/      Theme, PrimaryButton, Card, EmptyState, Haptics
  Logging/         Sentry/OSLog wrapper, Keychain helper
  Resources/       Assets.xcassets

Supabase/
  migrations/      schema, RLS, triggers, RPCs
  powersync/       sync rules
  functions/
    notify-price-change/  Edge Function: APNs fan-out on new lows

web/                static landing + public list viewer (Netlify-ready)
  index.html
  l/index.html      renders any /l/<token> share link
  styles.css        shared theme; CSS variables match iOS
  js/
    list.js         vanilla module, fetches via Supabase REST RPCs
    config.example.js   template for Supabase URL + anon key
  .well-known/
    apple-app-site-association   Universal Links manifest (template)
```

## Status

This is a comprehensive scaffold. The architecture is in place across all features, but the project has not yet been built against a real Mac/Xcode toolchain — expect a small round of compile-time fixes when you run `xcodegen generate && open DeadWaxClub.xcodeproj` and hit ⌘B for the first time. Areas where SDK API names move between minor versions and may need a tweak:

- **PowerSync Swift SDK** — `DeadWaxClub/Sync/*` and the repos use names matching the documented 1.x API.
- **`supabase-swift` 2.x** — OAuth helpers and `signInWithIdToken` occasionally rename. `DeadWaxClub/Auth/AuthClient.swift` is the focal point.
- **AppIntents** — the `DisplayRepresentation.Image(url:)` initializer and the parameter syntax have evolved across iOS 17.x; small adjustments may be needed.

## Development notes

- `AppServices` constructs and owns long-lived objects. Views read them via `@EnvironmentObject`.
- All deletions are soft (`deleted_at`) so PowerSync propagates tombstones reliably.
- Cover art lookup order on display: local Caches file → Supabase Storage public URL → Discogs URL → SF Symbol placeholder. First display of any record both writes the bytes to disk and uploads to Supabase Storage so subsequent launches and other devices render it without Discogs.
- Sharing a list with `link_public` mode mints a 12-char token and a public URL. The unauthenticated `get_shared_list` and `get_shared_list_records` RPCs serve the data — no Dead Wax Club account required to view.
- DeadWaxClub.xcodeproj is regenerated from `project.yml`. Don't commit it.
