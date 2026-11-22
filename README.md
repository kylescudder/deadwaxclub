# Deadwax Club

Native iOS app (SwiftUI, iOS 17+) for tracking the vinyl you own and the vinyl you want. Offline-first, syncs to Postgres, scans barcodes in shops, plots price changes over time, alerts you when a record on your wishlist drops to a new low, and lets you share lists with friends — privately, by link, or collaboratively.

## Features

- Email/password, Sign in with Apple, and Google sign-in (Better Auth on the Herman API)
- Offline-first SQLite mirrored to PostgreSQL on Herman via self-hosted PowerSync
- Owned / Wishlist tabs with sort + filter (year, colour way, has-price)
- Manual entry, barcode scanning, and Discogs lookup for cover art / artist / colour way
- Per-record price history with a Swift Charts line graph
- Discogs marketplace estimated value, clearly distinguished from prices you actually paid
- **Shareable lists** — private, public link, invite-only, or fully collaborative
- **Push notifications** when any wishlist record (yours or one a list-mate added) hits a new all-time low price
- **Stats** — total spent, collection value, breakdown by decade and colour way, top owned, lowest wishlist
- Cover art cached on device **and** mirrored to the API (`/api/covers/`) so cover art works fully offline and other devices fetch it instead of Discogs
- **AppIntents + Spotlight** — find records from system search, "Hey Siri, log a price in Deadwax Club"
- **Onboarding sheets** for display name, Discogs token, and notification permission
- Light / Dark / System appearance toggle
- Account deletion (App Store 5.1.1(v) compliant)
- Error reporting via Sentry (optional)

## Stack

| Concern        | Tool                                                              |
| -------------- | ----------------------------------------------------------------- |
| UI             | SwiftUI, iOS 17+                                                  |
| Backend        | Bun/TypeScript API in `Backend/` with PostgreSQL on Herman        |
| Sync           | [PowerSync Swift SDK](https://github.com/powersync-ja/powersync-swift) |
| Auth           | Better Auth (email, Sign in with Apple, Google)                   |
| Metadata       | [Discogs API](https://www.discogs.com/developers) (release + marketplace stats) |
| Charts         | Swift Charts                                                      |
| Barcode        | VisionKit `DataScannerViewController`                             |
| Push           | APNs via the shared push gateway (`docs/push-gateway/`)           |
| Search         | CoreSpotlight + AppIntents                                        |
| Error logging  | `sentry-cocoa`                                                    |
| Project gen    | [XcodeGen](https://github.com/yonaskolb/XcodeGen)                 |

## First-time setup

The fastest path is the bundled script:

```sh
./setup.sh
```

It checks for required tools, copies the secrets templates, generates the Xcode project, and prints what's still left (anything Apple-Developer-related). The detailed steps below are what the script automates — useful as a reference if you want to do anything by hand.

### 1. Install tools

```sh
brew install xcodegen oven-sh/bun/bun
```

### 2. Configure secrets

```sh
cp Config/Secrets.xcconfig.example Config/Secrets.xcconfig
```

Fill in:

- `API_URL`: the Deadwax API origin (for example `https://auth.deadwaxclub.app`).
- `POWERSYNC_URL`: the PowerSync origin (for example `https://sync.deadwaxclub.app`).
- `SENTRY_DSN` from a Sentry project (optional — leave blank to disable).

### 3. Backend

The API, database schema and PowerSync sync config live in `Backend/`. The historical Supabase migrations are replayed from `Backend/db/legacy/` under their original names. `Backend/deploy/README.md` covers local checks and the Herman deployment order: shared PostgreSQL, PowerSync, recovery proofs and releases.

Sign-in providers (email, Apple, Google) and the redirect URI `deadwaxclub://auth-callback` are configured in the API's protected `api.env`; `Backend/deploy/api.env.example` lists the values.

### 4. Push notifications

Lowest-price alerts and invites are delivered through the shared APNs gateway. See `docs/push-gateway/README.md`.

### 5. In-app subscriptions

Deadwax Club uses StoreKit for the `club.deadwax.supporter.monthly` auto-renewable subscription. The bundled StoreKit configuration file lets simulator builds load the product locally; App Store Connect is still the source for TestFlight/App Store pricing.

1. In App Store Connect, create an auto-renewable subscription with product ID `club.deadwax.supporter.monthly`.
2. Set the UK monthly price to £1.99 or the nearest App Store pricing equivalent.
3. Configure App Store Server Notifications V2 to the API's `/api/iap/notifications` endpoint. The app mirrors verified transactions to `/api/iap/transactions`.

### 6. Website and public list viewer

The Astro site under `Site/` serves the marketing page, support, privacy and terms pages, public list links (`/l/<token>`) and the Universal Links manifest at **https://deadwaxclub.app**. For local work:

```sh
cp Site/public/js/config.example.js Site/public/js/config.js
# config.js points at the Deadwax API origin (https://auth.deadwaxclub.app)
bun run dev
```

See `Site/README.md` for the site commands and checks.

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

## Website deployment

Merging a change under `Site/` to `main` runs `.github/workflows/release-site.yml`.
It repeats the site checks (`ci-site.yml`), builds a multi-architecture image of
the static site served by an unprivileged, read-only Caddy container, publishes
it to `ghcr.io/kylescudder/deadwaxclub-site` with GitHub build provenance, then
asks Herman to deploy that exact digest. Herman's shared deploy-core service
verifies the provenance, swaps the container, checks the pages, assets and Apple
association, rolls back on failure and acknowledges the revision; the workflow
waits until the public site reports it in `X-Deadwax-Revision`.

The release needs these GitHub settings. Variables are repository-level because
the deploy job's condition is evaluated before it enters the `production`
environment; the secrets live in that main-only environment.

| Setting | Kind | Purpose |
|---|---|---|
| `API_BASE_URL` | repository variable | Deadwax API origin; the list viewer reads shared lists from it |
| `DEPLOY_HOST` | repository variable | Herman deploy hostname, protected by Cloudflare Access |
| `SITE_BASE_URL` | repository variable | Public origin checked for the new revision |
| `CF_ACCESS_CLIENT_ID`, `CF_ACCESS_CLIENT_SECRET` | `production` secrets | Access service token for the deploy hostname |
| `DEPLOY_WEBHOOK_SECRET` | `production` secret | HMAC key for deploy requests |

Host setup, rollback and the receiver live in Herman's platform runbook and the
`kylescudder/deploy-core` repository, not in this repository.

## Repo layout

```
DeadWaxClub/
  App/             entry point, services container, secrets, AppDelegate
  Auth/            AuthClient, sign-in views, Apple + Google flows
  Sync/            PowerSync schema, manager, status indicator
  Records/         list, detail, add, log price, sort, filter, repos
  Scanner/         VisionKit DataScanner + permission handling
  Discogs/         release + marketplace stats client
  CoverArt/        on-device + API cover cache
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

Backend/            Bun/TypeScript API (Better Auth, uploads, IAP, covers)
  db/               app SQL adapters; legacy/ holds the historical Supabase migrations
  deploy/           Compose, PowerSync service + sync config, Herman runbook
  test/             backend, infrastructure and quota tests

Site/               Astro marketing site + public list viewer
  src/pages/        routes for /, /l, /privacy, and /terms
  src/styles.css    shared viewer/legal theme; CSS variables match iOS
  public/js/
    list.js         vanilla module, fetches shared lists from the Deadwax API
    config.example.js   template for the Deadwax API origin
  public/.well-known/
    apple-app-site-association   Universal Links manifest
```

## Status

This is a comprehensive scaffold. The architecture is in place across all features, but the project has not yet been built against a real Mac/Xcode toolchain — expect a small round of compile-time fixes when you run `xcodegen generate && open DeadWaxClub.xcodeproj` and hit ⌘B for the first time. Areas where SDK API names move between minor versions and may need a tweak:

- **PowerSync Swift SDK** — `DeadWaxClub/Sync/*` and the repos use names matching the documented 1.x API.
- **AppIntents** — the `DisplayRepresentation.Image(url:)` initializer and the parameter syntax have evolved across iOS 17.x; small adjustments may be needed.

## Development notes

- `AppServices` constructs and owns long-lived objects. Views read them via `@EnvironmentObject`.
- All deletions are soft (`deleted_at`) so PowerSync propagates tombstones reliably.
- Cover art lookup order on display: local Caches file → API cover URL → Discogs URL → SF Symbol placeholder. First display of any record both writes the bytes to disk and uploads it to the API so subsequent launches and other devices render it without Discogs.
- Sharing a list with `link_public` mode mints a 12-char token and a public URL. The unauthenticated `get_shared_list` and `get_shared_list_records` RPCs serve the data — no Deadwax Club account required to view.
- DeadWaxClub.xcodeproj is regenerated from `project.yml`. Don't commit it.
