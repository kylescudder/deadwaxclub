# Deadwax Club

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
- **AppIntents + Spotlight** — find records from system search, "Hey Siri, log a price in Deadwax Club"
- **Onboarding sheets** for display name, Discogs token, and notification permission
- Light / Dark / System appearance toggle
- Account deletion (App Store 5.1.1(v) compliant)
- Error reporting via Sentry (optional)

## Stack

| Concern        | Tool                                                              |
| -------------- | ----------------------------------------------------------------- |
| UI             | SwiftUI, iOS 17+                                                  |
| Backend        | Self-hosted Supabase (Postgres 17 + GoTrue + PostgREST + Storage + Edge Functions) |
| Sync           | Self-hosted [PowerSync Service](https://github.com/powersync-ja/powersync-service) + [PowerSync Swift SDK](https://github.com/powersync-ja/powersync-swift) |
| Auth           | `supabase-swift` (email, Sign in with Apple, Google)              |
| Metadata       | [Discogs API](https://www.discogs.com/developers) (release + marketplace stats) |
| Charts         | Swift Charts                                                      |
| Barcode        | VisionKit `DataScannerViewController`                             |
| Push           | APNs via Supabase Edge Function (Deno)                            |
| Search         | CoreSpotlight + AppIntents                                        |
| Error logging  | `sentry-cocoa`                                                    |
| Project gen    | [XcodeGen](https://github.com/yonaskolb/XcodeGen)                 |

## First-time setup

The fastest path is the bundled script:

```sh
./setup.sh
```

It checks for required tools, copies the secrets templates, applies Supabase migrations against your linked project, generates the Xcode project, and prints what's still left (anything Apple-Developer-related). The detailed steps below are what the script automates — useful as a reference if you want to do anything by hand.

### 1. Install tools

```sh
brew install xcodegen supabase/tap/supabase
```

### 2. Configure secrets

```sh
cp Config/Secrets.xcconfig.example Config/Secrets.xcconfig
```

Fill in:

- `SUPABASE_URL` — the API hostname for your Supabase instance. Self-hosted: `https://api.<your-domain>` (the Caddy/Kong entrypoint). Supabase Cloud: `https://<project>.supabase.co`.
- `SUPABASE_ANON_KEY` — the `anon` JWT.
- `POWERSYNC_URL` — your PowerSync service hostname. Self-hosted: `https://powersync.<your-domain>`. PowerSync Cloud: `https://<instance>.powersync.journeyapps.com`.
- `SENTRY_DSN` — optional, leave blank to disable.

### 3. Provision Supabase

The production deployment self-hosts via the official [`supabase/supabase`](https://github.com/supabase/supabase) docker-compose stack on a Hetzner box, fronted by Caddy with auto-TLS. You can also run against Supabase Cloud — both paths use the same migrations.

Apply migrations:

```sh
# Self-hosted
for f in supabase/migrations/*.sql; do
  docker exec -i <your-db-container> psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q < "$f"
done

# Supabase Cloud
supabase link --project-ref <your-project>
supabase db push
```

Configure OAuth providers. Self-hosted Supabase reads these as GoTrue env vars on the `auth` service (set them in `docker-compose.override.yml` or `.env`):

```
GOTRUE_EXTERNAL_APPLE_ENABLED=true
GOTRUE_EXTERNAL_APPLE_CLIENT_ID=com.deadwaxclub.app   # iOS bundle ID
GOTRUE_EXTERNAL_GOOGLE_ENABLED=true
GOTRUE_EXTERNAL_GOOGLE_CLIENT_ID=<from Google Cloud OAuth web client>
GOTRUE_EXTERNAL_GOOGLE_SECRET=<from Google Cloud OAuth web client>
```

Supabase Cloud users do the same in **Authentication → Providers** in the dashboard. Either way, add both redirect URIs to Apple/Google:
- `https://<your-api-host>/auth/v1/callback`
- `deadwaxclub://auth-callback`

### 4. Provision PowerSync

PowerSync replicates Postgres → on-device SQLite. Postgres needs:
- `wal_level=logical` (the `supabase/postgres` image ships with this)
- The `powersync` publication, created by `supabase/migrations/0009_powersync_publication.sql`
- A replication role with `BYPASSRLS` and read access to `public` + `auth`:
  ```sql
  CREATE ROLE powersync_replicator WITH REPLICATION LOGIN PASSWORD '...' BYPASSRLS;
  GRANT USAGE ON SCHEMA public, auth TO powersync_replicator;
  GRANT SELECT ON ALL TABLES IN SCHEMA public, auth TO powersync_replicator;
  ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO powersync_replicator;
  ```

Then either run [`journeyapps/powersync-service`](https://hub.docker.com/r/journeyapps/powersync-service) alongside your Supabase stack (with MongoDB for sync state) or create an instance at <https://powersync.com>. Either way, mount `supabase/powersync/sync_rules.yaml` as the service's sync rules, and put the resulting hostname into `POWERSYNC_URL` in `Secrets.xcconfig`.

### 5. Push notifications (optional but recommended)

For lowest-price and collection-invite alerts:

1. In the Apple Developer portal, create an APNs Auth Key (`.p8`).
2. Inject APNs secrets into the `functions` container env (self-hosted: `.env` / `docker-compose.override.yml`; Cloud: dashboard **Edge Functions → Secrets**):
   - `APNS_TEAM_ID` — your team ID
   - `APNS_KEY_ID` — the key's ID
   - `APNS_PRIVATE_KEY` — full contents of the `.p8` file
   - `APNS_BUNDLE_ID` — `com.deadwaxclub.app` (or your own)
3. Deploy the functions:
   ```sh
   supabase functions deploy notify-inbox notify-price-change
   ```
4. Wire the triggers. **Self-hosted**: `supabase/migrations/0020_notification_triggers.sql` installs in-DB triggers on `notifications` and `price_entries` that POST to the edge functions via `pg_net`. The anon key has to be set as a per-database GUC so the triggers can authenticate:
   ```sql
   ALTER DATABASE postgres SET app.anon_key = '<your anon key>';
   ```
   **Supabase Cloud**: skip migration 0020 and instead create Database Webhooks in the dashboard on `notifications` INSERT → `notify-inbox`, and `price_entries` INSERT → `notify-price-change` (header `Authorization: Bearer <SUPABASE_ANON_KEY>`).

The `notify-price-change` function only writes a `notifications` row when the trigger flags `is_new_low`, so you won't get spammed. `notify-inbox` is the single APNs fan-out.

### 6. Public list web viewer (optional)

A small static site under `web/` renders public-link lists in any browser and serves the Universal Links manifest. Drop it onto Netlify (or any static host) at `deadwaxclub.app`:

```sh
cp web/js/config.example.js web/js/config.js
# Edit config.js with your Supabase URL + anon key
npx netlify deploy --dir=web --prod
```

Edit `web/.well-known/apple-app-site-association` and replace `TEAMID.com.deadwaxclub.app` with your real Apple Team ID + bundle. The `applinks:deadwaxclub.app` entry is already in `DeadWaxClub.entitlements`. After this is live, tapping any `https://deadwaxclub.app/l/<token>` link from another iOS app launches Deadwax Club directly; if the app isn't installed, the recipient sees the web list.

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
  -destination 'generic/platform=iOS Simulator'
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

supabase/
  config.toml      supabase CLI config (local dev only)
  migrations/      schema, RLS, triggers, RPCs (0020 wires in-DB notification triggers for self-hosted)
  powersync/       sync rules (edition 3)
  functions/
    notify-inbox/         Edge Function: APNs fan-out for any notifications row
    notify-price-change/  Edge Function: writes a price_alert notification when is_new_low

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
- Sharing a list with `link_public` mode mints a 12-char token and a public URL. The unauthenticated `get_shared_list` and `get_shared_list_records` RPCs serve the data — no Deadwax Club account required to view.
- DeadWaxClub.xcodeproj is regenerated from `project.yml`. Don't commit it.
