# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Deadwax Club — native iOS 17+ SwiftUI app for tracking owned/wishlist vinyl, plus a small static web viewer for public list links and a Supabase backend (Postgres + Auth + Storage + Edge Functions). Offline-first via PowerSync.

## Common commands

The Xcode project is generated from `project.yml` and is git-ignored — regenerate after any source/dependency change.

```sh
xcodegen generate                          # rebuild DeadWaxClub.xcodeproj from project.yml
open DeadWaxClub.xcodeproj                 # open in Xcode (⌘R to run, ⌘B to build)
xcodebuild build \                         # CLI sanity build (no signing required)
  -project DeadWaxClub.xcodeproj \
  -scheme DeadWaxClub \
  -destination 'generic/platform=iOS Simulator'
./setup.sh                                 # idempotent first-run: tools, secrets templates, migrations, xcodegen
```

Supabase (CLI must be `supabase login`'d and `supabase link`'d):

```sh
supabase db push                                              # apply Supabase/migrations/*.sql
supabase functions deploy notify-price-change                 # APNs fan-out edge function
```

Web (static, no build step):

```sh
cp web/js/config.example.js web/js/config.js                  # then edit with Supabase URL + anon key
npx netlify deploy --dir=web --prod
```

There is no test suite, linter, or formatter configured. Don't invent commands for them.

## Secrets and configuration

- iOS secrets live in `Config/Secrets.xcconfig` (git-ignored, copied from `Config/Secrets.xcconfig.example`). Values are surfaced into Swift via `Info.plist` → `DeadWaxClub/App/AppSecrets.swift`. **xcconfig escaping gotcha**: `//` must be written as `/$()/` (the example file shows this for `https://...`). Empty strings are treated as "feature disabled" — don't add fatal errors for unset secrets.
- Web config lives in `web/js/config.js` (git-ignored, copied from `config.example.js`). The Supabase anon key is intentionally shipped to the browser; RLS + the `get_shared_list*` RPCs gate what's actually exposed.
- Supabase Edge Function secrets (`APNS_TEAM_ID`, `APNS_KEY_ID`, `APNS_PRIVATE_KEY`, `APNS_BUNDLE_ID`) are set in the Supabase dashboard, not in any local file.

## Architecture

### iOS app composition

- `DeadWaxClubApp` → injects a single `@StateObject AppServices` into the environment. Every view reads dependencies via `@EnvironmentObject AppServices`.
- `AppServices` (`DeadWaxClub/App/AppServices.swift`) is the composition root. It owns `AuthClient`, `PowerSyncManager`, `DiscogsClient`, `CoverArtCache`, the four repositories (`RecordsRepository`, `PriceEntriesRepository`, `ProfileRepository`, `ListsRepository`), and `OnboardingCoordinator`. It re-broadcasts each child's `objectWillChange` so the whole tree reacts to any sub-publisher.
- `RootView` switches on `auth.state` (`.unknown` / `.signedOut` / `.signedIn`) and presents onboarding sheets, deep-link record sheets, and public-list sheets above `MainTabView` (Records / Scan / Lists / Stats / Settings).
- Auth-gated lifecycle: `AppServices.applyAuth` reacts to sign-in/out — starts `ProfileRepository` and `ListsRepository` watchers, kicks onboarding evaluation, registers for push. `PowerSyncManager.reconcile` connects on sign-in and `disconnectAndClear()`s on sign-out.

### Sync (PowerSync ↔ Supabase)

- Local SQLite schema is declared in `DeadWaxClub/Sync/DatabaseSchema.swift`; the same tables exist in Postgres via `Supabase/migrations/0001_init.sql`+. **These two must stay in lock-step** — adding a column means migrating Postgres, updating `DatabaseSchema.swift`, and updating `Supabase/powersync/sync_rules.yaml`.
- All repositories read via `database.watch(sql:...)` — UI is reactive on local SQLite, writes go through PowerSync which streams to Postgres in the background. Don't query Postgres directly from the app; write to the local DB and let PowerSync replicate.
- All deletions are soft (`deleted_at` timestamp) — required so PowerSync propagates tombstones reliably across devices. Every `select` filters `where deleted_at is null`.
- Cover art lookup order on display: local Caches file → Supabase Storage public URL (`covers` bucket) → Discogs URL → SF Symbol placeholder. First display of any record both writes bytes to disk *and* uploads to Supabase Storage so other devices fetch from the user's bucket instead of Discogs.
- Push notifications: Postgres `BEFORE INSERT` trigger on `price_entries` sets `is_new_low`; a Supabase webhook fires the `notify-price-change` edge function which fans out to APNs only when `is_new_low` is true. Token registration lives in `DeadWaxClub/Notifications/PushManager.swift` and writes to the `device_tokens` table.

### List sharing

- `lists.share_mode` ∈ {`private`, `link_public`, `invite_only`, `collaborative`}. Public-link mode mints a 12-char `share_token`.
- The web viewer (`web/l/index.html` + `web/js/list.js`) calls two unauthenticated `security definer` RPCs from `0004_lists.sql`: `get_shared_list(token)` and `get_shared_list_records(token)`. Flipping a list off `link_public` immediately revokes web access — no redeploy needed.
- Universal Links: `https://deadwaxclub.app/l/<token>` opens the iOS app via `applinks:deadwaxclub.app` in `DeadWaxClub.entitlements` + `web/.well-known/apple-app-site-association`. The custom scheme `deadwaxclub://list/<token>` is the in-app fallback. Both are handled in `RootView.handle(url:)`.

### Other notable wiring

- Spotlight + AppIntents indexing happens inside `RecordsRepository.startWatching` (calls `SpotlightIndex.index(records:)` after each watch tick). Tapping a Spotlight result re-enters via `RootView.onContinueUserActivity("com.apple.corespotlightitem")` and posts `Notification.Name.openRecord`, which `AppServices` resolves against local SQLite.
- Sentry/OSLog wrapper is `DeadWaxClub/Logging/Logger.swift` (`Log.error`, `Log.breadcrumb`). Sentry is no-op when `SENTRY_DSN` is empty.
- The Discogs personal token is per-user, entered in Settings, stored in the keychain (`Logging/Keychain.swift`). The onboarding flow nags on first launch.

### Folder casing

The Supabase folder is `Supabase/` (capital S) on disk; the README and `setup.sh` reference it as `supabase/`. macOS is case-insensitive by default so both work locally — when scripting paths, prefer the on-disk casing (`Supabase/migrations/...`) to stay portable.

## Strict concurrency

`SWIFT_STRICT_CONCURRENCY: complete` is set in `project.yml`. Most singletons are `@MainActor` (services, repositories, view models). When adding new types that cross actor boundaries, expect the compiler to demand `Sendable` conformance — don't paper over with `@unchecked Sendable` unless you've actually reasoned about it.

## SDK drift

The recent commit history (`grep "API drift"` in git log) shows ongoing chase against minor-version SDK renames. Areas most prone to breakage when bumping packages:

- **PowerSync Swift SDK** — `DeadWaxClub/Sync/*` and the repos use names matching the documented 1.x API; check `nonisolated` annotations on cover helpers.
- **`supabase-swift` 2.x** — OAuth helpers and `signInWithIdToken` arg order/labels move between minors. `DeadWaxClub/Auth/AuthClient.swift` is the focal point.
- **AppIntents** — `DisplayRepresentation.Image(url:)` initializer and parameter syntax shift across iOS 17.x.

When something fails to build after a package bump, investigate the SDK changelog before "fixing" call sites — the renames usually have a single canonical answer rather than each call site needing bespoke treatment.

## What not to commit

`Config/Secrets.xcconfig`, `web/js/config.js`, `DeadWaxClub.xcodeproj/`, `Supabase/.temp/`, `Supabase/.branches/`, `.netlify/`. All gitignored already — don't add overrides.
