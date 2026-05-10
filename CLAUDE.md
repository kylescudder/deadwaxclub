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
supabase db push                                              # apply supabase/migrations/*.sql
supabase functions deploy notify-inbox                        # APNs fan-out for any notifications row
supabase functions deploy notify-price-change                 # legacy producer that writes price-alert rows
```

Web (static, no build step locally):

```sh
cp web/js/config.example.js web/js/config.js                  # local dev only — production is generated at deploy
npx netlify deploy --dir=web --prod                           # Netlify runs web/build-config.sh which writes config.js from env
```

There is no test suite, linter, or formatter configured. Don't invent commands for them.

## Secrets and configuration

- iOS secrets live in `Config/Secrets.xcconfig` (git-ignored, copied from `Config/Secrets.xcconfig.example`). Values are surfaced into Swift via `Info.plist` → `DeadWaxClub/App/AppSecrets.swift`. **xcconfig escaping gotcha**: a literal `//` in a value (e.g. `https://...`) must be written `https:/$()/...` to keep the parser from treating the rest of the line as a comment. Empty strings are treated as "feature disabled" — don't add fatal errors for unset secrets.
- Web config lives in `web/js/config.js` (git-ignored). At deploy time `web/build-config.sh` (wired from `netlify.toml`) writes that file from Netlify env vars `SUPABASE_URL` and `SUPABASE_ANON_KEY`. The local copy of `config.js` from `config.example.js` is for running the site against your dev Supabase off-Netlify; don't paste real secrets there. The Supabase anon key is intentionally shipped to the browser; RLS + the `get_shared_list*` RPCs gate what's actually exposed.
- Supabase Edge Function secrets (`APNS_TEAM_ID`, `APNS_KEY_ID`, `APNS_PRIVATE_KEY`, `APNS_BUNDLE_ID`) are set in the Supabase dashboard, not in any local file. Both `notify-inbox` and `notify-price-change` read the same set.

## Architecture

### iOS app composition

- `DeadWaxClubApp` → injects a single `@StateObject AppServices` into the environment and registers it on `IntentBridge.services` so AppIntents can talk to the same PowerSync database. Every view reads dependencies via `@EnvironmentObject AppServices`.
- `AppServices` (`DeadWaxClub/App/AppServices.swift`) is the composition root. It owns `AuthClient`, `PowerSyncManager`, `DiscogsClient`, `CoverArtCache`, and the repositories `RecordsRepository`, `PriceEntriesRepository`, `RecordImagesRepository`, `ProfileRepository`, `ListsRepository`, `CollectionsRepository`, `NotificationsRepository`, plus `OnboardingCoordinator`. It re-broadcasts each child's `objectWillChange` so the whole tree reacts to any sub-publisher.
- `RootView` switches on `auth.state` (`.unknown` / `.signedOut` / `.signedIn`) and presents onboarding sheets, deep-link record sheets, deep-link Collection sheets (`pendingDeepLinkCollectionID`), and public-list sheets above `MainTabView` (Records / Scan / Lists / Stats / Settings).
- Auth-gated lifecycle: `AppServices.applyAuth` reacts to sign-in/out — starts `ProfileRepository`, `ListsRepository`, `CollectionsRepository`, and `NotificationsRepository` watchers, kicks onboarding evaluation, registers for push. `PowerSyncManager` reacts independently via `startObservingAuth`.
- `AppServices.ingestDiscogsImages(recordID:collectionID:sourceURLs:)` is the single save-time entry point for Discogs images. Call it from any save site (`AddRecordView`, `ScanResultSheet`, `RecordDetailView`) instead of writing to `RecordImagesRepository` directly — it persists rows *and* eagerly mirrors bytes into Supabase Storage so the user doesn't have to swipe to that carousel slide for the upload to happen. `mirrorPendingImages(forRecord:)` is the on-appear catch-up for any rows that didn't get mirrored at save time.

### Sync (PowerSync ↔ Supabase)

- Local SQLite schema is declared in `DeadWaxClub/Sync/DatabaseSchema.swift`; the same tables exist in Postgres via `supabase/migrations/*.sql`. **These two must stay in lock-step** — adding a column means migrating Postgres, updating `DatabaseSchema.swift`, updating `supabase/powersync/sync_rules.yaml`, *and* adding the table to the `powersync` Postgres publication (the most recent migration recreates the publication; do the same in any new migration that introduces a synced table).
- Sync rules are **edition 3** (`supabase/powersync/sync_rules.yaml`): use `auth.user_id()` (not `request.user_id()`); only single-level subqueries are allowed (`where x in (select … from t where …)`), no nested joins. The composite-PK tables (`collection_members`, `list_members`) synthesise an `id` via `collection_id || ':' || user_id` so PowerSync can key rows locally.
- All repositories read via `database.watch(sql:...)` — UI is reactive on local SQLite, writes go through PowerSync which streams to Postgres in the background. Don't query Postgres directly from the app; write to the local DB and let PowerSync replicate.
- **PowerSync exposes synced tables as views** so `INSERT … ON CONFLICT … DO UPDATE` is rejected. The repository pattern is `insert or ignore (...) values (...)` followed by an unconditional `update ... where id = ?` — both branches end with the row in the desired state. Repeat that shape in any new repository code.
- `SupabaseConnector` (`DeadWaxClub/Sync/SupabaseConnector.swift`) implements `PowerSyncBackendConnectorProtocol`. PowerSync keeps the row's primary key in `entry.id` rather than inside `opData`; the connector merges `payload["id"] = entry.id` before each `.put` upsert — without that, PostgREST sends an INSERT with a null id and Postgres rejects it (FK or RLS, surfaced as a misleading 42501).
- `PowerSyncManager.disconnect()` (used on transient `.signedOut` from session refreshes) does *not* clear local state. `wipe()` calls `disconnectAndClear()` and is reserved for explicit user sign-out from Settings — calling it on every transient state would wipe the local DB and the pending CRUD upload queue. The `.unknown` auth state during bootstrap intentionally leaves PowerSync alone for the same reason.
- All deletions are soft (`deleted_at` timestamp) — required so PowerSync propagates tombstones reliably across devices. Every `select` filters `where deleted_at is null`.
- All UUIDs are lowercased at every callsite (`UUID().uuidString.lowercased()`, `currentUserID?.uuidString.lowercased()`). SQLite's `=` is case-sensitive while Postgres normalises to lowercase, so mixing cases produces "row exists in Postgres but not SQLite" desyncs. Match the convention.
- Cover art lookup order on display: local Caches file → Supabase Storage public URL (`covers` bucket) → Discogs URL → SF Symbol placeholder. First display of any record both writes bytes to disk *and* uploads to Supabase Storage so other devices fetch from the user's bucket instead of Discogs.

### Collections (records visibility model)

- A user belongs to one or more **Collections** via `collection_members` (`role ∈ {owner, editor, viewer}`). The Records tab shows the union of records across every Collection the user is in; queries gate visibility with `where collection_id in (select collection_id from collection_members where user_id = ?)`. This is the same one-level subquery shape edition-3 sync rules use, so the local query and the sync stream agree on visibility.
- The signup trigger (`handle_new_user` in `0017_handle_new_user_split_first_name.sql`) creates a personal Collection per user, makes them its `owner`, and points `profiles.primary_collection_id` at it. New records default to that Collection. Pending email invites for both Collections and Lists are auto-accepted by the same trigger.
- RLS on collection-scoped tables (`collections`, `collection_members`, `records`, `price_entries`, `record_images`) goes through `security definer` helper functions `is_collection_member` / `is_collection_writer` / `is_collection_owner` (`0019_fix_collection_members_recursion.sql`). The helpers run with the function-owner's privileges and skip RLS, which is what breaks the recursion that an inlined `exists (select … from collection_members …)` policy hits. **Never inline that subquery in a new policy** — call the helpers.

### Notifications inbox

- The single source of truth for user-facing notifications is `public.notifications`. Anything that wants to ping a user inserts a row; a Postgres webhook on INSERT fires the `notify-inbox` Edge Function, which looks up the user's `device_tokens` and fans out APNs. The iOS bell icon (`NotificationInboxView`) reads the same table via `NotificationsRepository`, so push and inbox always agree.
- `notification_kind ∈ {price_alert, collection_invite}`. `notify-price-change` is the legacy producer for price alerts (it inserts a price_alert row when its `BEFORE INSERT` trigger on `price_entries` flags `is_new_low`). `invite_to_collection` (RPC) is the producer for collection_invite. New event kinds drop in by inserting a row — no new function needed.
- APNs payloads carry a `kind` discriminator. `PushManager`'s notification-tap handler routes `collection_invite` to `Notification.Name.openCollection` (handled by `AppServices` → sets `pendingDeepLinkCollectionID` → `RootView` presents `ManageCollectionsView`), and falls back to `record_id` → `Notification.Name.openRecord` for legacy/price-alert pushes (handled by `openRecordByID` against local SQLite).

### Multi-image carousel

- Records have an arbitrary number of images via `record_images` (kind ∈ `discogs` / `user_upload`, ordered by `position`). The primary image (position 0) is also kept on `records.cover_art_storage_path` for backwards-compat with Spotlight, the records list, and any consumer of `CoverArtCache.displayURL(for:)`.
- `record_images.collection_id` is denormalised so PowerSync edition-3 rules can gate visibility with one subquery (the `member_record_images` stream). RLS uses the same `is_collection_member` / `is_collection_writer` helpers.
- Bytes live in the same `covers` Supabase Storage bucket as the primary cover; `CoverArtCache.mirrorIfNeeded(image:)` handles Discogs → Storage mirroring per row.

### List sharing

- `lists.share_mode` ∈ {`private`, `link_public`, `invite_only`, `collaborative`}. Public-link mode mints a 12-char `share_token`.
- The web viewer (`web/l/index.html` + `web/js/list.js`) calls two unauthenticated `security definer` RPCs from `0004_lists.sql`: `get_shared_list(token)` and `get_shared_list_records(token)`. Flipping a list off `link_public` immediately revokes web access — no redeploy needed.
- Universal Links: `https://deadwaxclub.app/l/<token>` opens the iOS app via `applinks:deadwaxclub.app` in `DeadWaxClub.entitlements` + `web/.well-known/apple-app-site-association`. The custom scheme `deadwaxclub://list/<token>` is the in-app fallback. Both are handled in `RootView.handle(url:)`.
- Edition-3 caveat: records on lists where the viewer is a list-member but not in the record's Collection still cannot be expressed as a sync stream (it would need a 2-level join `list_members → list_items → records`). Records the viewer *owns* always sync via `member_records` because that's a one-level join through `collection_members`. The remaining gap (curated public/collaborative lists pulling in records the viewer doesn't already own) is filled by REST fetches in the list views.

### Other notable wiring

- Spotlight + AppIntents indexing happens inside `RecordsRepository.startWatching` (calls `SpotlightIndex.index(records:)` after each watch tick). Tapping a Spotlight result re-enters via `RootView.onContinueUserActivity("com.apple.corespotlightitem")` and posts `Notification.Name.openRecord`, which `AppServices` resolves against local SQLite.
- AppIntents (`DeadWaxClub/Intents/`) run outside the SwiftUI environment. `IntentBridge` is the static escape hatch — `DeadWaxClubApp` registers `AppServices` on it at launch, and intents query/write through `services.sync.database` directly.
- Sentry/OSLog wrapper is `DeadWaxClub/Logging/Logger.swift` (`Log.error`, `Log.breadcrumb`). Sentry is no-op when `SENTRY_DSN` is empty.
- The Discogs personal token is per-user, entered in Settings, stored in the keychain (`Logging/Keychain.swift`). The onboarding flow nags on first launch.
- `Preferences.currency` (`DeadWaxClub/Settings/Preferences.swift`) is the single source for the user's preferred ISO 4217 code; it falls back to the device locale and finally GBP. Use it instead of reading `UserDefaults` directly when displaying or persisting prices.
- The app is locked to portrait and hides the status bar (`UISupportedInterfaceOrientations` + `UIStatusBarHidden` in `DeadWaxClub/Info.plist`). The `Info.plist` is committed; `project.yml`'s `info.properties` only adds the secrets/scenes/background-modes keys on top.

## Strict concurrency

`SWIFT_STRICT_CONCURRENCY: complete` is set in `project.yml`. Most singletons are `@MainActor` (services, repositories, view models). When adding new types that cross actor boundaries, expect the compiler to demand `Sendable` conformance — don't paper over with `@unchecked Sendable` unless you've actually reasoned about it. `SupabaseConnector` is `@unchecked Sendable` because PowerSync calls it off-main and the Supabase client it holds is itself thread-safe; new connector-shaped types should justify the same way.

## SDK drift

The recent commit history (`grep "API drift"` in git log) shows ongoing chase against minor-version SDK renames. Areas most prone to breakage when bumping packages:

- **PowerSync Swift SDK** — `DeadWaxClub/Sync/*` and the repos use names matching the documented 1.x API. The connector adopts `PowerSyncBackendConnectorProtocol` (the post-deprecation name); callbacks like `fetchCredentials` and `uploadData` keep the protocol's signatures. Check `nonisolated` annotations on cover helpers when something fails to build.
- **`supabase-swift` 2.x** — OAuth helpers and `signInWithIdToken` arg order/labels move between minors. `DeadWaxClub/Auth/AuthClient.swift` is the focal point.
- **AppIntents** — `DisplayRepresentation.Image(url:)` initializer and parameter syntax shift across iOS 17.x.

When something fails to build after a package bump, investigate the SDK changelog before "fixing" call sites — the renames usually have a single canonical answer rather than each call site needing bespoke treatment.

## Folder casing

The Supabase folder is `supabase/` (lowercase) on disk and the README, `setup.sh`, and `netlify.toml` all use that casing. macOS is case-insensitive by default so `Supabase/` works locally too — the `.gitignore` keeps both forms for safety — but always write `supabase/migrations/...` in new code, scripts, or docs to stay portable to case-sensitive filesystems.

## What not to commit

`Config/Secrets.xcconfig`, `web/js/config.js`, `DeadWaxClub.xcodeproj/`, `supabase/.temp/`, `supabase/.branches/`, `.netlify/`. All gitignored already — don't add overrides.
