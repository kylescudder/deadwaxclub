# Shared iOS app conventions

Every iOS app uses the same repository layout, tooling and app scaffolding.
No app refers to another app by name: shared files use the hooks below. The files in
`shared-ios-core.sha256` are byte-for-byte identical in every app. `@APP@` in
that manifest is the `name:` from `project.yml`, and the iOS workflows may
differ only in that name, which the check normalizes. Run
`sh Scripts/check-shared-ios-core.sh`; iOS CI runs the same check alongside
the shared auth and push core checks.

To change a shared file, make the same edit in every app, run
`sh Scripts/check-shared-ios-core.sh --write` in one of them, copy the changed
files and the manifest to the others, compare them, and run every app's iOS
build and tests. Never fork a shared file to fit one app: move the app-specific
part behind one of the app hooks below instead.

## Repository layout

```text
<App>/                     app target sources (layout below)
<App>Tests/                unit tests; Shared*Tests.swift are identical in every app
<App>Widgets/              WidgetKit extension
Backend/                   Bun API, PostgreSQL migrations, PowerSync config (see SHARED_INFRA.md)
Site/                      Astro marketing, support and legal site (see SHARED_SITE.md)
Config/                    Secrets.xcconfig.example (Secrets.xcconfig is git-ignored)
Scripts/                   shared-code manifests and checks, setup-extras.sh, ci/ExportOptions.plist
docs/                      longer-form docs, including push-gateway.md
deploy/                    host healthcheck notes
project.yml                XcodeGen spec; the .xcodeproj is generated and git-ignored
setup.sh                   first-run setup (shared)
AGENTS.md                  agent guide; CLAUDE.md contains only `@AGENTS.md`
README.md                  human guide
```

Top-level folders are capitalized except `docs/` and `deploy/`. Preserve the
spelling in code, scripts and workflow paths so the repository works on
case-sensitive filesystems.

## App target layout

```text
<App>/App/                 <App>App, AppDelegate*, AppServices, AppBootstrap*, AppSecrets*, RootView, QuickActionRouter*, AppQuickAction
<App>/Auth/                AuthClient, APIClient, AppleSignIn, GoogleSignIn (shared auth), SignInView*, ForgotPasswordSheet*, ResetPasswordSheet*, AppleSignInButton*, AuthAppConfiguration, SignUpView
<App>/Billing/             BillingRepository*, SubscriptionAccessState*, CreationQuotaProviding*, SubscriptionPaywallView*, BillingAppConfiguration
<App>/Components/          Theme*, LoadingView*, LottieAnimationView*, PrimaryButton*, Card*, EmptyState*, Theme+App, other app primitives
<App>/Extensions/          Foundation+Helpers.swift and other type extensions
<App>/Intents/             AppIntents and App Shortcuts
<App>/Logging/             Logger* (`Log`)
<App>/Models/              Codable/PowerSync row models
<App>/Notifications/       shared push core and adapters (SHARED_PUSH_CORE.md), PushAppConfiguration, app-only notification features
<App>/Resources/           Assets.xcassets, <App>.icon, Animations/, StoreKit/<App>.storekit, Fonts/
<App>/Settings/            SettingsView, AppearanceManager*, PushAuthorizationRow*, ProfileRepository, preferences
<App>/Sync/                PowerSyncManager*, APIConnector*, SyncIssueStore*, DatabaseSchema, SyncAppConfiguration, SyncIssueStore+App
<App>/Utilities/           small app-only helpers (formatters, Keychain wrappers)
<App>/Widgets/             AppGroupStore*, WidgetSnapshotStore (both compiled into the app and the widget)
<App>/<Feature>/           one folder per product area: its views and repositories together
```

`*` marks files in the shared manifest. A repository lives in its feature's
folder; the profile repository lives in `Settings/`.

## App hooks

The shared files read app-specific values from these places only:

- `project.yml` `name:` — the target, scheme, project and folder name, and the
  test target's `-module-alias AppUnderTest=<App>` flag.
- The `*.auth` URL type in `project.yml` — `AppSecrets.authRedirectURL`.
- `Auth/AuthAppConfiguration.swift` — callback scheme, Keychain service and
  other values the shared auth code needs, plus the sign-in screen's logo,
  title and tagline, how the reset-password sheet is left
  (`passwordRecoveryExit`).
- `App/AppQuickAction.swift` — the quick actions, their pending-storage key
  and where each routes; URL parsing for them stays app-specific.
- `Widgets/WidgetSnapshotStore.swift` — the app group ID, widget kinds and
  snapshot types, stored through the shared `AppGroupStore`.
- `Billing/BillingAppConfiguration.swift` — the StoreKit product ID, the
  verification-pending message, the paywall headline, body and usage text,
  and the privacy and terms URLs.
- `AppServices.creationQuota` — the app's creation-quota repository, adopting
  `CreationQuotaProviding`, whose lifetime count the paywall shows.
- `Sync/DatabaseSchema.swift` — the local PowerSync schema.
- `Sync/SyncAppConfiguration.swift` — the SQLite filename, the offline-owner
  query, the writable-table allowlist, the permanent rejection codes, the
  local-clear failure message, and the `didUpload`/`didReject` callbacks that
  hold the app's pending-creation ledger and quota replay rules.
- `Sync/SyncIssueStore+App.swift` — the app's sync issue reports and copy.
- `Notifications/PushAppConfiguration.swift` — the installation-ID Keychain
  item, the fallback bundle ID, the notification-tap routes
  (`SHARED_PUSH_CORE.md`) and the `PushAuthorizationRow` copy.
- `Components/Theme+App.swift` — `Theme.loadingAnimation`, the
  `Theme.CardStyle` tokens (`padding`, `cornerRadius`, `fillsWidth`,
  `showsBorder`) that give `Card` the app's look, and any brand
  colours, added as `extension Theme.Colors`. Use the shared semantic colours
  (`textPrimary`, `textSecondary`, `accent`, `separator`, …) rather than aliases.
- `Backend/package.json` `packageManager` — the Bun version `setup.sh` enforces.
- `Scripts/setup-extras.sh` (optional) — app-only setup steps, sourced by
  `setup.sh` with its `step`/`ok`/`warn`/`note` helpers.
- `PROVISIONING_PROFILE_SPECIFIER` in `project.yml` — the profile names the
  TestFlight workflow installs (app first, widgets second).
- GitHub secrets `IOS_<APP>_PROFILE_BASE64` and
  `IOS_<APP>_WIDGETS_PROFILE_BASE64`, where `<APP>` is the upper-case name.

## Conventions

- **Configuration.** Build values flow `Config/Secrets.xcconfig` → `project.yml`
  `info.properties` → `Info.plist` → `AppSecrets`. Escape `//` as `/$()/`. The
  example uses `.invalid` placeholders, which `AppSecrets` treats as unset, so
  pull-request builds compile without a backend and report a configuration
  error instead of crashing. An empty `SENTRY_DSN` disables Sentry.
- **Composition.** `<App>App` owns one `@StateObject AppServices`, injects it
  with `environmentObject`, installs the shared `AppDelegate`, applies the
  saved `Appearance` and calls `AppBootstrap.configureSentry()`.
  `AppServices` is the composition root and re-broadcasts its children's
  `objectWillChange`. It creates `AuthClient`, `SyncIssueStore`,
  `PowerSyncManager(auth:issues:)` and `BillingRepository(auth:)`, binds
  `PushManager.shared` with `auth.beforeSessionInvalidation` (deactivate) and
  `afterSessionInvalidationFailure` (activate), starts billing and
  `sync.startObservingAuth()`, and exposes `creationQuota`. Its `applyAuth`
  replaces account repositories through `sync.accountDatabaseDidChange` before
  publishing sign-in, starts the feature watches and push activation on sign-in, and on sign-out
  calls `PushManager.sessionEnded()`, `billing.resetForSignOut()` and stops
  the watches. `RootView` bootstraps auth with `sync.offlineAccount`, shows
  the shared `SignInView` until `auth.canAccessMainApp`, presents
  `ResetPasswordSheet` during password recovery and `SyncIssueStore` issues
  as alerts, and on each foreground transition calls
  `QuickActionRouter.activate()`, `PushManager.refreshRegistration()` and
  `sync.retryConnection()`. The tabs, feature repositories, `Profile` model,
  `SignUpView` fields and Settings sections stay per app.
- **Logging.** Errors go through `Log` (OSLog plus Sentry), never `print`.
- **Data.** Repositories read with `database.watch` and write to local SQLite;
  PowerSync uploads through `APIConnector`. Deletes are soft (`deleted_at`).
  UUIDs sent to SQLite or the API are lowercased.
- **Concurrency.** `SWIFT_STRICT_CONCURRENCY: complete`. Services and
  repositories are `@MainActor`; justify any `@unchecked Sendable`.
- **Plists.** Info.plist, entitlements and ExportOptions use Xcode's format:
  tab indentation and keys in alphabetical order.
- **Tests.** Every test file imports the app as `@testable import AppUnderTest`.
  The test target maps that name to the app's module with
  `OTHER_SWIFT_FLAGS: $(inherited) -module-alias AppUnderTest=<App>` in
  `project.yml`, so `Shared*Tests.swift` never name an app.
- **CI.** `ios-build.yml` runs the shared checks, an unsigned simulator build
  and the unit tests on any available iPhone simulator. `ios-testflight.yml`
  archives `main` with manual signing, verifies the release endpoints and the
  archived configuration, and uploads to TestFlight.

## Shared feature cores

Feature code that every app needs is shared too. Each core reads its app
values from the hooks above, and its `Shared*Tests.swift` covers the rules
below. Change a rule in every app at once, together with its tests.

### Billing

`BillingRepository` is StoreKit 2 with server mirroring:

- Purchases pass the signed-in user's UUID as `appAccountToken`.
- A locally verified, active entitlement moves `subscriptionState` to
  `.verifying`. Only a `/api/iap/transactions` response with `active: true`
  (and not `verified: false`) moves it to `.active`. `isSubscribed` is
  `.active` or `hasAccessOverride`, which every app sets from the synced
  `profiles.is_premium_account` flag.
- Transactions are finished only after the server confirms them. StoreKit
  re-delivers an unfinished transaction through `Transaction.updates`, so a
  failed mirror is retried on the next launch. A revoked or expired update is
  mirrored too, so the server's entitlement row stops granting access, and
  finished once the server has stored it; an entitlement sync follows, so
  access ends in-session.
- The mirror is retried three times (0.5 s, then 1 s) only for connectivity
  and 5xx failures. Client errors, sign-in failures and an inactive verdict
  are final and leave the state `.verifying` with the app's message.
- Sign-out resets the in-memory state, including the override.
- **Complimentary access is required in every app.** `profiles.is_premium_account`
  is a non-null boolean, default false, controlled only by the database
  administrator. Keep it out of profile-upload allowlists and deny request-role
  INSERT/UPDATE privileges on that column. Sync it in the owner profile stream,
  represent it in the local schema and `Profile`, and bind profile changes to
  `BillingRepository.setAccessOverride` in `AppServices`. A missing profile is
  false; account replacement and sign-out must clear the in-memory override.
- Server quota status and insert enforcement both accept the premium flag OR a
  cryptographically verified, active subscription. The existing
  `has_verified_entitlement` quota-response field represents either grant of
  unlimited creation. Offline status and local writes must accept the same flag
  from the account's cached profile. Keep counting lifetime creations while
  premium is enabled; revocation restores the cap without resetting usage.
  Revocation is effective offline once the new profile has synced. Do not forge
  StoreKit entitlement rows or mark a complimentary account's subscription active.
- Shared composition tests cover profile-to-billing propagation, offline account
  restoration, revocation and account isolation. Shared billing tests ensure
  StoreKit refresh does not erase complimentary access, and removing it does not
  remove a separately confirmed subscription.

Each app's creation-quota gate (server status endpoint, offline quota and
entitlement snapshot, pending-creation ledger and free limit) stays in its
feature folder. Billing only reads the lifetime count through
`CreationQuotaProviding`.

### Sync

`PowerSyncManager`, `APIConnector` and `SyncIssueStore` are the PowerSync
connection, upload and issue core:

- Each authenticated UUID selects a separate SQLite file and CRUD queue before
  the session is published. Feature repositories are recreated against that
  handle; an old task can never start writing into the next account's file.
- Sign-out (including offline sign-out and password-recovery exit) closes the
  account database without clearing it. Signing back in reopens its rows and
  pending queue. A signed-out screen never identifies a retained account.
- `offlineAccount()` verifies ownership of the legacy database. Its original
  owner keeps that file in place, including local-only tables, the sync cursor,
  and pending CRUD; other accounts get separate files. Unverifiable legacy
  ownership fails closed rather than guessing or dropping queued writes.
- Only account deletion or explicit "Sign out and remove local data" clears
  the selected account. Other databases and their queues are untouched.
- The connector is bound to that owner. Credentials and every upload use the
  owner's current token, and uploads without it throw and stay queued.
- Only tables in the writable allowlist upload; anything else throws.
- Only the app's permanent rejection codes are acknowledged (after its
  `didReject` hook runs). Network, 5xx, authentication, RLS (`42501`) and
  unknown failures throw so PowerSync retries them. Never add a code without
  proving it cannot succeed on retry.

Schema, writable tables, error codes and quota replay rules stay in the app's
hooks.

## Adding an app

Copy every file in this manifest, `shared-auth.sha256`, `shared-push-core.sha256`,
`shared-infra.sha256` and `shared-site.sha256` from an existing app, then add the
app's own hooks above, `AGENTS.md`, `README.md` (same section order as the other
apps) and `project.yml`. The site has its own hooks, starting with
`Site/app.json`; see `SHARED_SITE.md`. Give the test target the
`-module-alias AppUnderTest=<App>` flag. All five checks must pass before the
first pull request.
