# Deadwax Club

Native iOS 17+ SwiftUI app for tracking the vinyl you own and the vinyl you want,
with an Astro marketing site and public list viewer at **deadwaxclub.app**.
Offline-first, it syncs to PostgreSQL, scans barcodes in shops, plots price
changes over time, alerts you when a record on your wishlist drops to a new low,
and lets you share lists with friends — privately, by link, or collaboratively.

## Features

- Email/password, Sign in with Apple and Google sign-in (Better Auth on the Herman API)
- Offline-first SQLite mirrored to PostgreSQL on Herman through self-hosted PowerSync
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
- Supporter subscription for unlimited records
- Light / Dark / System appearance
- Account deletion (App Store 5.1.1(v) compliant)
- Error reporting through Sentry (optional)

## Stack

| Concern       | Tool                                                                   |
| ------------- | ---------------------------------------------------------------------- |
| UI            | SwiftUI, iOS 17+, WidgetKit, AppIntents                                |
| Backend       | Bun/TypeScript API in `Backend/` with PostgreSQL on Herman             |
| Sync          | [PowerSync Swift SDK](https://github.com/powersync-ja/powersync-swift) |
| Auth          | Better Auth (email, Sign in with Apple, Google), Brevo email           |
| Subscriptions | StoreKit 2, verified server-side with Apple's server library           |
| Push          | APNs through the shared push gateway (`docs/push-gateway.md`)          |
| Metadata      | [Discogs API](https://www.discogs.com/developers) (release + marketplace stats) |
| Charts        | Swift Charts                                                           |
| Barcode       | VisionKit `DataScannerViewController`                                  |
| Search        | CoreSpotlight + AppIntents                                             |
| Error logging | `sentry-cocoa`                                                         |
| Project gen   | [XcodeGen](https://github.com/yonaskolb/XcodeGen)                      |

## Repo layout

Every iOS app shares this layout; [Scripts/SHARED_IOS_CORE.md](Scripts/SHARED_IOS_CORE.md)
is the reference.

```
DeadWaxClub/
  App/             entry point, AppServices, AppSecrets, AppDelegate, routing
  Auth/            AuthClient, APIClient, sign-in views, Apple + Google flows
  Billing/         StoreKit repository, paywall
  Collections/     shared collections and membership
  Components/      Theme, Theme+App, Card, PrimaryButton, LoadingView, EmptyState, Lottie
  CoverArt/        on-device + API cover cache, camera, carousel
  Discogs/         release + marketplace stats client
  Extensions/      Foundation helpers
  Intents/         AppIntents, AppShortcuts, Spotlight indexing
  Lists/           lists CRUD, share modes, public viewer
  Logging/         OSLog/Sentry wrapper
  Models/          VinylRecord, PriceEntry, Profile, VinylList, ...
  Notifications/   shared push core, APNs registration, inbox
  Onboarding/      first-run sheets
  Records/         list, detail, add, log price, sort, filter, repositories
  Resources/       assets, DeadWaxClub.icon, animations, fonts, StoreKit configuration
  Scanner/         VisionKit DataScanner + permission handling
  Settings/        settings, appearance, preferences, profile repository
  Stats/           aggregates + Swift Charts
  Sync/            PowerSync schema, manager, connector, sync issues
  Utilities/       currency formatting, Keychain helper
  Widgets/         widget snapshot store (shared with the extension)
DeadWaxClubTests/   unit tests
DeadWaxClubWidgets/ WidgetKit extension

Backend/            Bun API (Better Auth, uploads, IAP, covers), PowerSync config, Herman deploy
  db/               migrations/ (numbered domain schema SQL) and the migration runner
  drizzle/          Better Auth tables
Site/               Astro marketing site + public list viewer
Config/             Secrets.xcconfig.example
Scripts/            shared-code checks, setup extras, CI export options
docs/               push gateway contract and research notes
```

## Getting started

```sh
./setup.sh
```

The script checks for Homebrew, XcodeGen and the pinned Bun (1.4.4), copies
`Config/Secrets.xcconfig.example` to `Config/Secrets.xcconfig` and
`Site/public/js/config.example.js` to `Site/public/js/config.js` if they don't
exist, installs the backend dependencies and generates `DeadWaxClub.xcodeproj`.
It never touches a production backend.

Fill in `Config/Secrets.xcconfig`:

- `API_URL`: the Deadwax API origin (`https://auth.deadwaxclub.app`).
- `POWERSYNC_URL`: the PowerSync origin (`https://sync.deadwaxclub.app`).
- `PUSH_GATEWAY_URL`: optional; leave blank to register devices with the API.
- `SENTRY_DSN`: optional; leave blank to disable Sentry.

Escape URL slashes as `https:/$()/...` in xcconfig. The example's placeholders
build fine but show configuration errors instead of signing in or syncing.

`DeadWaxClub.xcodeproj` is git-ignored: run `xcodegen generate` after changing
sources, targets, signing or dependencies, then open it and press ⌘R. Barcode
scanning needs a real device.

In the running app, add a Discogs personal token under **Settings → Discogs API**
(from <https://www.discogs.com/settings/developers>). It's stored in the
Keychain, and the onboarding sheet asks for it on first launch.

## Development

```sh
xcodebuild build -project DeadWaxClub.xcodeproj -scheme DeadWaxClub -configuration Debug \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
xcodebuild test -project DeadWaxClub.xcodeproj -scheme DeadWaxClub \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

Backend checks (see [Backend/deploy/README.md](Backend/deploy/README.md)):

```sh
cd Backend
bun install --frozen-lockfile
TEST_DATABASE_URL=postgresql://.../disposable_database bun test
```

The domain schema is the numbered SQL in `Backend/db/migrations/`, applied in
order by `Backend/db/application.ts`; add a new numbered file for every change and
never edit or rename an applied one. Better Auth's tables are in
`Backend/drizzle/`. Integration tests create and drop disposable databases. Never
use a production URL.

The site runs with `bun run dev`, `bun run build` and `bun run preview` from the
repository root; see [Site/README.md](Site/README.md) for its checks.

## Apple setup

Running on a device or shipping needs Apple Developer access:

1. App IDs `com.deadwaxclub.app` (Sign in with Apple, Push Notifications, App
   Groups, Associated Domains) and `com.deadwaxclub.app.widgets` (App Groups),
   both in app group `group.com.deadwaxclub.app`.
2. App Store provisioning profiles named **DeadwaxClub App Store** and
   **DeadwaxClub Widgets App Store** (the names in `project.yml`).
3. An auto-renewable subscription `club.deadwax.supporter.monthly` (UK monthly
   price £1.99 or the nearest equivalent). The committed
   `DeadWaxClub/Resources/StoreKit/DeadWaxClub.storekit` serves simulator builds;
   App Store Connect is authoritative for TestFlight and production.
4. App Store Server Notifications V2 pointed at the API's
   `/api/iap/notifications`.
5. A Sign in with Apple Services ID `com.deadwaxclub.app.signin` and key, plus
   Google credentials, in the API's protected `api.env` on Herman
   (`Backend/deploy/api.env.example` lists them). The native redirect is
   `deadwaxclub://auth-callback`.
6. The Apple Team ID in `Site/public/.well-known/apple-app-site-association`, so
   `https://deadwaxclub.app/l/<token>` opens the app.

## Releasing

Merging to `main` releases each changed area.

### Backend

`release-backend.yml` repeats the backend checks, builds and attests the API
image (`ghcr.io/kylescudder/deadwaxclub-api`) and sends a signed request through
Cloudflare Access to the receiver in `Backend/deploy/app.json` (`deployURL`). On
Herman, deploy-core:

1. verifies provenance and backs up the database;
2. requires a fresh off-host recovery proof;
3. runs migrations;
4. installs the image's Compose files, PowerSync configuration and inventory;
5. starts the API and PowerSync, rolling back on failure.

The workflow waits until Herman reports the digest deployed and
`API_BASE_URL/health/live` answers. See
[Backend/deploy/README.md](Backend/deploy/README.md) and deploy-core's
`docs/shared-backends.md`.

| Setting | Kind | Purpose |
|---|---|---|
| `API_BASE_URL` | repository variable | Public API origin checked after a deploy |
| `API_CF_ACCESS_CLIENT_ID`, `API_CF_ACCESS_CLIENT_SECRET` | `production` secrets | Access service token for the API deploy hostname |
| `API_DEPLOY_WEBHOOK_SECRET` | `production` secret | HMAC key for API deploy requests |

### Site

`release-site.yml` repeats the site checks (`ci-site.yml`), builds a
multi-architecture image of the static site served by an unprivileged, read-only
Caddy container, publishes it to `ghcr.io/kylescudder/deadwaxclub-site` with
GitHub build provenance, then asks Herman to deploy that exact digest. Herman's
deploy-core verifies the provenance, swaps the container, checks the pages,
assets and Apple association, rolls back on failure and acknowledges the
revision; the workflow waits until the public site reports it in
`X-Deadwax-Revision`. Variables are repository-level because the deploy job's
condition is evaluated before it enters the `production` environment.

| Setting | Kind | Purpose |
|---|---|---|
| `API_BASE_URL` | repository variable | Deadwax API origin; the list viewer reads shared lists from it |
| `DEPLOY_HOST` | repository variable | Herman deploy hostname, protected by Cloudflare Access |
| `SITE_BASE_URL` | repository variable | Public origin checked for the new revision |
| `CF_ACCESS_CLIENT_ID`, `CF_ACCESS_CLIENT_SECRET` | `production` secrets | Access service token for the deploy hostname |
| `DEPLOY_WEBHOOK_SECRET` | `production` secret | HMAC key for deploy requests |

Host setup, rollback and the receiver live in Herman's platform runbook and the
`kylescudder/deploy-core` repository.

### iOS app

`ios-testflight.yml` runs when the app, widgets, `project.yml`, the secrets
example or `Scripts/ci/` change on `main`. It checks that the release API and
PowerSync endpoints are ready, archives with manual signing, checks the archived
configuration and uploads to TestFlight. Run it manually with a delivery UUID to
wait for Apple's processing of an earlier upload.

| Setting | Kind | Purpose |
|---|---|---|
| `API_BASE_URL`, `POWERSYNC_BASE_URL` | repository variables | Release origins written into the build |
| `IOS_SECRETS_XCCONFIG` | secret | Release `Secrets.xcconfig` (the origins above replace its URLs) |
| `APP_STORE_CONNECT_API_KEY_ID`, `APP_STORE_CONNECT_API_KEY_ISSUER_ID`, `APP_STORE_CONNECT_API_KEY_P8` | secrets | App Store Connect API key for upload |
| `APPLE_TEAM_ID` | secret | Development team written into `project.yml` |
| `IOS_DISTRIBUTION_CERTIFICATE_BASE64`, `IOS_DISTRIBUTION_CERTIFICATE_PASSWORD`, `IOS_KEYCHAIN_PASSWORD` | secrets | Distribution certificate and temporary keychain |
| `IOS_DEADWAXCLUB_PROFILE_BASE64`, `IOS_DEADWAXCLUB_WIDGETS_PROFILE_BASE64` | secrets | The two App Store provisioning profiles |

## Shared code

Deadwax Club keeps five sets of files byte-for-byte identical with the other iOS
apps. CI fails if any of them drift:

| Check | Covers |
|---|---|
| `Scripts/check-shared-ios-core.sh` | App scaffolding, shared UI primitives, the billing and sync cores, `setup.sh`, iOS workflows ([SHARED_IOS_CORE.md](Scripts/SHARED_IOS_CORE.md)) |
| `Scripts/check-shared-auth.sh` | Better Auth backend and native auth ([SHARED_AUTH.md](Scripts/SHARED_AUTH.md)) |
| `Scripts/check-shared-push-core.sh` | Push registration core ([SHARED_PUSH_CORE.md](Scripts/SHARED_PUSH_CORE.md)) |
| `Scripts/check-shared-infra.sh` | Backend deployment and provisioning ([SHARED_INFRA.md](Scripts/SHARED_INFRA.md)) |
| `Scripts/check-shared-site.sh` | Astro site layout, tooling, image and site workflows ([SHARED_SITE.md](Scripts/SHARED_SITE.md)) |

## Development notes

Each account keeps a separate local database and upload queue. Signing out retains offline changes on this device; signing back in resumes them. Choose **Sign out and remove local data** to discard that account’s local changes explicitly. A fresh sign-in requires connectivity.

[AGENTS.md](AGENTS.md) describes the architecture in detail. In short:

- `AppServices` owns the long-lived services and repositories; views read it with `@EnvironmentObject`.
- Repositories read local SQLite through `database.watch` and write locally; PowerSync uploads through `APIConnector`.
- Deletions are soft (`deleted_at`) and UUIDs are lowercased everywhere.
- Cover art lookup order on display: local Caches file → API cover URL → Discogs URL → SF Symbol placeholder. First display of any record both writes the bytes to disk and uploads them to the API.
- Sharing a list with `link_public` mode mints a 12-char token and a public URL. The API's unauthenticated `/api/public/get_shared_list` and `/api/public/get_shared_list_records` endpoints serve the data — no account required to view.
