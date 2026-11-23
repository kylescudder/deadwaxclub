# AGENTS.md

This file provides guidance to coding agents when working with code in this repository.

## Project

Deadwax Club — native iOS 17+ SwiftUI app for tracking owned/wishlist vinyl, plus an Astro marketing site and public list viewer. The backend is the Bun API in `Backend/` (Better Auth) with PostgreSQL and self-hosted PowerSync on Herman; the public list viewer reads shared lists from the API. Offline-first via PowerSync.

## Shared conventions

Every iOS app uses the same repository layout, app scaffolding and CI. Read
`Scripts/SHARED_IOS_CORE.md` before adding folders, shared UI primitives,
configuration keys or workflows. Five checksum manifests keep shared files
byte-for-byte identical with the other apps, and CI runs all of them:

- `Scripts/check-shared-ios-core.sh` — `AppSecrets`, `AppBootstrap`, `Theme`, `LoadingView`, `LottieAnimationView`, `PrimaryButton`, `Logger`, `AppearanceManager`, `Card`, `EmptyState`, `PushAuthorizationRow`, `AppDelegate`, `QuickActionRouter`, `AppGroupStore`, the shared sign-in views (`SignInView`, `ForgotPasswordSheet`, `ResetPasswordSheet`, `AppleSignInButton`), the billing core (`BillingRepository`, `SubscriptionAccessState`, `CreationQuotaProviding`, `SubscriptionPaywallView`), the sync core (`PowerSyncManager`, `APIConnector`, `SyncIssueStore`), the `Shared*Tests`, `setup.sh` and the iOS workflows.
- `Scripts/check-shared-auth.sh` — Better Auth backend and native auth (`SHARED_AUTH.md`).
- `Scripts/check-shared-push-core.sh` — push registration core and its adapters (`PushManager`, `PushRegistration`, `AuthClient+PushIdentity`; `SHARED_PUSH_CORE.md`).
- `Scripts/check-shared-infra.sh` — backend deployment and provisioning (`SHARED_INFRA.md`).
- `Scripts/check-shared-site.sh` — the `Site/` layout, tooling, image and site workflows (`SHARED_SITE.md`).

Never edit a shared file in one app only. Put app-specific values behind the
hooks listed in `SHARED_IOS_CORE.md` (`Theme+App.swift`, `AuthAppConfiguration`,
`BillingAppConfiguration`, `SyncAppConfiguration`, `PushAppConfiguration`,
`AppQuickAction`, `WidgetSnapshotStore`, `project.yml`,
`Scripts/setup-extras.sh`), or make the same change in every app and refresh
the manifest with `sh Scripts/check-shared-ios-core.sh --write`.

## Common commands

The Xcode project is generated from `project.yml` and is git-ignored — regenerate after any source, target, signing, or dependency change.

```sh
xcodegen generate                          # rebuild DeadWaxClub.xcodeproj from project.yml
open DeadWaxClub.xcodeproj                 # open in Xcode (⌘R to run, ⌘B to build)
xcodebuild build \                         # CLI sanity build (no signing required)
  -project DeadWaxClub.xcodeproj \
  -scheme DeadWaxClub \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO
xcodebuild test -project DeadWaxClub.xcodeproj -scheme DeadWaxClub -destination 'platform=iOS Simulator,name=iPhone 16'
./setup.sh                                 # first-run tools, secrets templates, backend deps, xcodegen
```

Web:

```sh
cp Site/public/js/config.example.js Site/public/js/config.js   # local dev only — releases generate it during the image build
bun run dev                                                    # installs Site deps and starts Astro
bun run build                                                  # builds Site/dist
```

iOS unit tests live in `DeadWaxClubTests/`; `Shared*Tests.swift` are identical in every app. There is no iOS linter or formatter. The Astro site uses the house tooling in `Site/` (`typecheck`, `lint`, `format:check`, `check:site`). Merging to `main` releases each changed area: `Site/` to Herman, `Backend/` (API, migrations, Compose and PowerSync config together) to Herman, and the app to TestFlight (see the README's Releasing section).

## Backend

Production runs on Herman. The runtime is `Backend/` (Bun 1.4.4, TypeScript,
PostgreSQL, Better Auth, Brevo and self-hosted PowerSync) on Herman's shared
PostgreSQL server. Read `Backend/deploy/README.md` for checks, migrations and
deployment before release work.

- The domain schema is the numbered SQL in `Backend/db/migrations/`, applied in order by `Backend/db/application.ts` and recorded in its ledger; add a new numbered file for every change and never edit or rename an applied one. Better Auth's tables are in `Backend/drizzle/`.
- Backend checks: `cd Backend && bun install --frozen-lockfile`, `TEST_DATABASE_URL=... bun test`. Tests require a disposable PostgreSQL database. Never point them at production.

## Push notifications

Before changing push registration, APNs delivery, `device_tokens` or notification
producers, read `docs/push-gateway.md` and keep its provider-neutral HTTP contract
identical across all application repositories.

## Secrets and configuration

- iOS secrets live in `Config/Secrets.xcconfig` (git-ignored, copied from `Config/Secrets.xcconfig.example`). Values are surfaced into Swift via `Info.plist` → `DeadWaxClub/App/AppSecrets.swift`. **xcconfig escaping gotcha**: a literal `//` in a value (e.g. `https://...`) must be written `https:/$()/...` to keep the parser from treating the rest of the line as a comment. Empty, unresolved and `.invalid` placeholder values are treated as "feature disabled" and surface as configuration errors — don't add fatal errors for unset secrets; simulator and pull-request builds deliberately use the example xcconfig.
- Web config lives in `Site/public/js/config.js` (git-ignored). Release images generate it with `Site/scripts/write-config.mjs` from the `API_BASE_URL` repository variable; the local copy from `config.example.js` points at the same API origin. It holds no secrets — the token-gated `/api/public/get_shared_list*` endpoints decide what's exposed.
- Backend secrets (database URLs, Better Auth, Apple/Google sign-in, IAP verification) live in the API's protected `api.env` on Herman; `Backend/deploy/api.env.example` lists them. Push goes through the shared APNs gateway. Never accept decoded JWS payloads as proof of entitlement.

## Architecture

### iOS app composition

- `DeadWaxClubApp` → injects a single `@StateObject AppServices` into the environment and registers it on `IntentBridge.services` so AppIntents can talk to the same PowerSync database. Every view reads dependencies via `@EnvironmentObject AppServices`.
- `AppServices` (`DeadWaxClub/App/AppServices.swift`) is the composition root. It owns `AuthClient`, `PowerSyncManager`, `DiscogsClient`, `CoverArtCache`, and the repositories `RecordsRepository`, `PriceEntriesRepository`, `RecordImagesRepository`, `ProfileRepository`, `ListsRepository`, `CollectionsRepository`, `NotificationsRepository`, plus `OnboardingCoordinator`. It re-broadcasts each child's `objectWillChange` so the whole tree reacts to any sub-publisher.
- `RootView` switches on `auth.state` (`.unknown` / `.signedOut` / `.signedIn`) and presents onboarding sheets, deep-link record sheets, deep-link Collection sheets (`pendingDeepLinkCollectionID`), and public-list sheets above `MainTabView` (Records / Scan / Lists / Stats / Settings).
- Auth-gated lifecycle: `AppServices.applyAuth` reacts to sign-in/out — starts `ProfileRepository`, `ListsRepository`, `CollectionsRepository`, and `NotificationsRepository` watchers, kicks onboarding evaluation, registers for push. `PowerSyncManager` reacts independently via `startObservingAuth`.
- `SignInView`, `ForgotPasswordSheet`, `ResetPasswordSheet`, `AppleSignInButton`, `QuickActionRouter`, `AppGroupStore` and `PushAuthorizationRow` are shared (`Scripts/SHARED_IOS_CORE.md`). Deadwax's sign-in branding, recovery exit (cancel) and onboarding reset live in `Auth/AuthAppConfiguration.swift`, its quick actions in `App/AppQuickAction.swift`, its widget snapshots in `Widgets/WidgetSnapshotStore.swift`. `SignUpView` (optional display name, resend confirmation) stays Deadwax-only.
- `AppServices.ingestDiscogsImages(recordID:collectionID:sourceURLs:)` is the single save-time entry point for Discogs images. Call it from any save site (`AddRecordView`, `ScanResultSheet`, `RecordDetailView`) instead of writing to `RecordImagesRepository` directly — it persists rows *and* eagerly mirrors bytes to the API cover store so the user doesn't have to swipe to that carousel slide for the upload to happen. `mirrorPendingImages(forRecord:)` is the on-appear catch-up for any rows that didn't get mirrored at save time.

### Sync (PowerSync ↔ Herman API)

- Local SQLite schema is declared in `DeadWaxClub/Sync/DatabaseSchema.swift`; the same synced tables exist in Postgres via `Backend/db/migrations/`, while `localOnly` tables are device-only. **These must stay in lock-step** — adding a synced column means migrating Postgres, updating `DatabaseSchema.swift`, updating `Backend/deploy/powersync/sync-config.yaml`, and adding the table to the `powersync` publication. Prefer `alter publication ... add table` over rebuilding the publication.
- Sync rules are **edition 3** (`Backend/deploy/powersync/sync-config.yaml`): use `auth.user_id()` (not `request.user_id()`); only single-level subqueries are allowed (`where x in (select … from t where …)`), no nested joins. The composite-PK tables (`collection_members`, `list_members`) synthesise an `id` via `collection_id || ':' || user_id` so PowerSync can key rows locally.
- All repositories read via `database.watch(sql:...)` — UI is reactive on local SQLite, writes go through PowerSync which streams to Postgres in the background. Don't query Postgres directly from the app; write to the local DB and let PowerSync replicate.
- **PowerSync exposes synced tables as views** so `INSERT … ON CONFLICT … DO UPDATE` is rejected. The repository pattern is `insert or ignore (...) values (...)` followed by an unconditional `update ... where id = ?` — both branches end with the row in the desired state. Repeat that shape in any new repository code.
- `PowerSyncManager`, `APIConnector` and `SyncIssueStore` are the shared sync core (rules in `Scripts/SHARED_IOS_CORE.md`, tests in `SharedSyncTests`). Deadwax's filename, offline-owner query, writable tables (`DatabaseSchema.writableTableNames`), `DW` codes and `pending_record_creations` replay rules are in `DeadWaxClub/Sync/SyncAppConfiguration.swift`, and its issue copy in `SyncIssueStore+App.swift`.
- `APIConnector` (`DeadWaxClub/Sync/APIConnector.swift`) implements `PowerSyncBackendConnectorProtocol`. PowerSync keeps the row's primary key in `entry.id` rather than inside `opData`; the connector merges `payload["id"] = entry.id` before each `.put` upsert sent to `/api/sync/upload` — without that, the INSERT has a null id and Postgres rejects it (FK or RLS, surfaced as a misleading 42501).
- Record creation is enforced by `record_creation_quotas`, the durable `record_creation_events` ledger, and the `records_enforce_creation_limit` trigger, not by a mutable records count. The trigger derives immutable `created_by` from the signed-in user, serializes creators, and counts creations for life across soft/hard deletion. Every profile receives a materialized zero quota row. Quotas and verified entitlements are read-only PowerSync snapshots; missing quota means initial sync is incomplete, not zero. Offline creates reserve allowance in local-only `pending_record_creations` in the same SQLite transaction as the record.
- `APIConnector` uses an explicit writable-table allowlist. Record PUTs use plain INSERT because their BEFORE INSERT trigger has lifetime side effects; a 23505 replay is acknowledged only after confirming the same record ID exists remotely. Known permanent validation/constraint failures are reported and acknowledged, while network, authentication, RLS, availability, and unexpected failures remain queued.
- `PowerSyncManager` selects one SQLite database and upload queue per authenticated account before publishing sign-in. Sign-out closes and retains it; account deletion or explicit removal clears only that account. Legacy ownership is verified once and its original file stays with that owner. Recreate feature repositories through `accountDatabaseDidChange` and never reuse a database handle across accounts.
- All deletions are soft (`deleted_at` timestamp) — required so PowerSync propagates tombstones reliably across devices. Every `select` filters `where deleted_at is null`.
- All UUIDs are lowercased at every callsite (`UUID().uuidString.lowercased()`, `currentUserID?.uuidString.lowercased()`). SQLite's `=` is case-sensitive while Postgres normalises to lowercase, so mixing cases produces "row exists in Postgres but not SQLite" desyncs. Match the convention.
- Cover art lookup order on display: local Caches file → API cover URL (`/api/covers/`) → Discogs URL → SF Symbol placeholder. First display of any record both writes bytes to disk *and* uploads to the API so other devices fetch it from the API instead of Discogs.

### Collections (records visibility model)

- A user belongs to one or more **Collections** via `collection_members` (`role ∈ {owner, editor, viewer}`). The Records tab shows the union of records across every Collection the user is in; queries gate visibility with `where collection_id in (select collection_id from collection_members where user_id = ?)`. This is the same one-level subquery shape edition-3 sync rules use, so the local query and the sync stream agree on visibility.
- The signup trigger (`handle_new_user`) creates a personal Collection per user, makes them its `owner`, and points `profiles.primary_collection_id` at it. New records default to that Collection. Pending email invites for both Collections and Lists are auto-accepted by the same trigger.
- RLS on collection-scoped tables (`collections`, `collection_members`, `records`, `price_entries`, `record_images`) goes through `security definer` helper functions `is_collection_member` / `is_collection_writer` / `is_collection_owner`. The helpers run with the function-owner's privileges and skip RLS, which is what breaks the recursion that an inlined `exists (select … from collection_members …)` policy hits. **Never inline that subquery in a new policy** — call the helpers.

### Notifications inbox

- The single source of truth for user-facing notifications is `public.notifications`. Anything that wants to ping a user inserts a row; each row becomes one `PushEvent v1` for the shared APNs gateway (`docs/push-gateway.md`), which looks up the user's installations and delivers to APNs. The iOS bell icon (`NotificationInboxView`) reads the same table via `NotificationsRepository`, so push and inbox always agree.
- `notification_kind ∈ {price_alert, collection_invite}`. Price alerts come from the `price_entries` trigger that flags `is_new_low`; `invite_to_collection` produces collection_invite. New event kinds drop in by inserting a row — no new function needed.
- `PushManager` (with `PushRegistration`, `AuthClient+PushIdentity` and `AppDelegate`) is the shared push coordinator (`Scripts/SHARED_PUSH_CORE.md`); Deadwax's Keychain item and tap routes live in `DeadWaxClub/Notifications/PushAppConfiguration.swift`.
- APNs payloads carry a `kind` discriminator. `PushAppConfiguration.route(for:)`, called by `PushManager`'s notification-tap handler, routes `collection_invite` to `Notification.Name.openCollection` (handled by `AppServices` → sets `pendingDeepLinkCollectionID` → `RootView` presents `ManageCollectionsView`), and falls back to `record_id` → `Notification.Name.openRecord` for price alerts (handled by `openRecordByID` against local SQLite).

### Multi-image carousel

- Records have an arbitrary number of images via `record_images` (kind ∈ `discogs` / `user_upload`, ordered by `position`). The primary image (position 0) is also kept on `records.cover_art_storage_path` for backwards-compat with Spotlight, the records list, and any consumer of `CoverArtCache.displayURL(for:)`.
- `record_images.collection_id` is denormalised so PowerSync edition-3 rules can gate visibility with one subquery (the `member_record_images` stream). RLS uses the same `is_collection_member` / `is_collection_writer` helpers.
- Bytes live in the same API cover store (`cover_objects`) as the primary cover; `CoverArtCache.mirrorIfNeeded(image:)` handles Discogs → API cover store mirroring per row.

### List sharing

- `lists.share_mode` ∈ {`private`, `link_public`, `invite_only`, `collaborative`}. Public-link mode mints a 12-char `share_token`.
- The web viewer (`Site/src/pages/l/index.astro` + `Site/public/js/list.js`) calls the API's unauthenticated `/api/public/get_shared_list` and `/api/public/get_shared_list_records`, backed by the `security definer` functions `get_shared_list(token)` and `get_shared_list_records(token)`. Flipping a list off `link_public` immediately revokes web access — no redeploy needed.
- Universal Links: `https://deadwaxclub.app/l/<token>` opens the iOS app via `applinks:deadwaxclub.app` in `DeadWaxClub.entitlements` + `Site/public/.well-known/apple-app-site-association`. The custom scheme `deadwaxclub://list/<token>` is the in-app fallback. Both are handled in `RootView.handle(url:)`.
- Edition-3 caveat: records on lists where the viewer is a list-member but not in the record's Collection still cannot be expressed as a sync stream (it would need a 2-level join `list_members → list_items → records`). Records the viewer *owns* always sync via `member_records` because that's a one-level join through `collection_members`. The remaining gap (curated public/collaborative lists pulling in records the viewer doesn't already own) is filled by REST fetches in the list views.

### Other notable wiring

- Spotlight + AppIntents indexing happens inside `RecordsRepository.startWatching` (calls `SpotlightIndex.index(records:)` after each watch tick). Tapping a Spotlight result re-enters via `RootView.onContinueUserActivity("com.apple.corespotlightitem")` and posts `Notification.Name.openRecord`, which `AppServices` resolves against local SQLite.
- AppIntents (`DeadWaxClub/Intents/`) run outside the SwiftUI environment. `IntentBridge` is the static escape hatch — `DeadWaxClubApp` registers `AppServices` on it at launch, and intents query/write through `services.sync.database` directly.
- Sentry/OSLog wrapper is `DeadWaxClub/Logging/Logger.swift` (`Log.error`, `Log.breadcrumb`, `Log.event`). Sentry is no-op when `SENTRY_DSN` is empty; keep repository and service errors going through `Log` rather than ad hoc prints.
- `Theme`, `Card`, `PrimaryButton`, `EmptyState` and `LoadingView` under `DeadWaxClub/Components/` are the shared UI primitives. Reuse them before introducing one-off colors, spacing, or loading treatments. App-only tokens (the loading animation and `Theme.CardStyle`, a roomy full-width borderless `Card`) live in `Theme+App.swift`.
- The Discogs personal token is per-user, entered in Settings, stored in the keychain (`Utilities/Keychain.swift`). The onboarding flow nags on first launch.
- `BillingRepository`, `SubscriptionAccessState` and `SubscriptionPaywallView` are the shared billing core (rules in `Scripts/SHARED_IOS_CORE.md`, tests in `SharedBillingTests`). Deadwax's values (`club.deadwax.supporter.monthly`, the verification message and paywall copy) live in `DeadWaxClub/Billing/BillingAppConfiguration.swift`; the paywall reads the lifetime record count through `AppServices.creationQuota` (`RecordsRepository`), and `profiles.is_premium_account` reaches billing as `setAccessOverride`. StoreKit's local `VerificationResult.verified` is device evidence only. `BillingRepository.isSubscribed` grants database-backed unlimited creation only after `/api/iap/transactions` has mirrored an Apple-cryptographically-verified active JWS (or the premium override is set); until then the state is `.verifying`, the paywall and Settings offer "Retry verification", and the transaction stays unfinished so StoreKit re-delivers it. Refunds, revocations and expiries from `Transaction.updates` are mirrored the same way, so the server entitlement row (which `canCreateNewRecord` also trusts) stops granting access, and are finished once stored. The API's `/api/iap/transactions` and App Store Server Notifications (`/api/iap/notifications`) paths use Apple's `SignedDataVerifier` with online certificate checks and call the service-only `apply_verified_iap_entitlement` function. A bypass must have the exact Deadwax bundle/product, Sandbox or Production environment, a verified source, transaction ID, signed timestamp, verified timestamp, and an active non-revoked, unexpired monthly subscription state (with a non-null Apple expiry). Entitlement updates are ordered by Apple's signed timestamp, so a delayed older event cannot undo a newer state. Never backfill these verification fields: pre-contract entitlement rows remain untrusted until a newly verified transaction or notification refreshes them.
- `Preferences.currency` (`DeadWaxClub/Settings/Preferences.swift`) is the single source for the user's preferred ISO 4217 code; it falls back to the device locale and finally GBP. Use it instead of reading `UserDefaults` directly when displaying or persisting prices.
- The app is locked to portrait and hides the status bar (`UISupportedInterfaceOrientations` + `UIStatusBarHidden` in `DeadWaxClub/Info.plist`). The `Info.plist` is committed (XcodeGen rewrites it with sorted keys); `project.yml`'s `info.properties` only adds the secrets/scenes/background-modes keys on top.

## Strict concurrency

`SWIFT_STRICT_CONCURRENCY: complete` is set in `project.yml`. Most singletons are `@MainActor` (services, repositories, view models). When adding new types that cross actor boundaries, expect the compiler to demand `Sendable` conformance — don't paper over with `@unchecked Sendable` unless you've actually reasoned about it. Connector types called by PowerSync off-main must justify any `@unchecked Sendable` with a concrete thread-safety argument.

## SDK drift

The recent commit history (`grep "API drift"` in git log) shows ongoing chase against minor-version SDK renames. Areas most prone to breakage when bumping packages:

- **PowerSync Swift SDK** — `DeadWaxClub/Sync/*` and the repos use names matching the documented 1.x API. The connector adopts `PowerSyncBackendConnectorProtocol` (the post-deprecation name); callbacks like `fetchCredentials` and `uploadData` keep the protocol's signatures. Check `nonisolated` annotations on cover helpers when something fails to build.
- **AppIntents** — `DisplayRepresentation.Image(url:)` initializer and parameter syntax shift across iOS 17.x.

When something fails to build after a package bump, investigate the SDK changelog before "fixing" call sites — the renames usually have a single canonical answer rather than each call site needing bespoke treatment.

## Folder casing

The app folders are `DeadWaxClub/`, `DeadWaxClubTests/` and `DeadWaxClubWidgets/`, the marketing site is `Site/` (capital S), the backend is `Backend/`, and the only lowercase top-level folders are `docs/` and `deploy/`. Always preserve those spellings in code, scripts, workflow paths, and documentation so the repository works on case-sensitive filesystems.

## What not to commit

`Config/Secrets.xcconfig`, `Site/public/js/config.js`, `.env*`, `DeadWaxClub.xcodeproj/`, `build/`, `DerivedData/`, `.build/`, `.swiftpm/`, `Package.resolved`, `Site/node_modules/`, `Site/.astro/`, `Site/dist/`, or signing certificates/provisioning profiles. These are already git-ignored where applicable; don't add overrides.
