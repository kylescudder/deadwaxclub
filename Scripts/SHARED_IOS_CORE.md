# Shared iOS app conventions

Every iOS app (Diald, Deadwax Club and any new app) uses the same repository
layout, tooling and app scaffolding. The files in `shared-ios-core.sha256` are
byte-for-byte identical in every app. `@APP@` in that manifest is the `name:`
from `project.yml`, and the iOS workflows may differ only in that name, which
the check normalizes. Run `sh Scripts/check-shared-ios-core.sh`; iOS CI runs
the same check alongside the shared auth and push core checks.

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
<App>/App/                 <App>App, AppDelegate, AppServices, AppBootstrap*, AppSecrets*, RootView, QuickActionRouter
<App>/Auth/                AuthClient, APIClient, AppleSignIn, GoogleSignIn (shared auth), AuthAppConfiguration, sign-in views
<App>/Billing/             BillingRepository*, SubscriptionAccessState*, CreationQuotaProviding*, SubscriptionPaywallView*, BillingAppConfiguration
<App>/Components/          Theme*, LoadingView*, LottieAnimationView*, PrimaryButton*, Theme+App, Card and other app primitives
<App>/Extensions/          Foundation+Helpers.swift and other type extensions
<App>/Intents/             AppIntents and App Shortcuts
<App>/Logging/             Logger* (`Log`)
<App>/Models/              Codable/PowerSync row models
<App>/Notifications/       shared push core and the app's push/notification adapters
<App>/Resources/           Assets.xcassets, <App>.icon, Animations/, StoreKit/<App>.storekit, Fonts/
<App>/Settings/            SettingsView, AppearanceManager*, ProfileRepository, preferences
<App>/Sync/                DatabaseSchema, PowerSyncManager, APIConnector, SyncIssueStore
<App>/Utilities/           small app-only helpers (formatters, Keychain wrappers)
<App>/Widgets/             WidgetSnapshotStore (compiled into the app and the widget)
<App>/<Feature>/           one folder per product area: its views and repositories together
```

`*` marks files in the shared manifest. A repository lives in its feature's
folder; the profile repository lives in `Settings/`.

## App hooks

The shared files read app-specific values from these places only:

- `project.yml` `name:` — the target, scheme, project and folder name.
- The `*.auth` URL type in `project.yml` — `AppSecrets.authRedirectURL`.
- `Auth/AuthAppConfiguration.swift` — callback scheme, Keychain service and
  other values the shared auth code needs.
- `Billing/BillingAppConfiguration.swift` — the StoreKit product ID, the
  verification-pending message, the paywall headline, body and usage text,
  and the privacy and terms URLs.
- `AppServices.creationQuota` — the app's creation-quota repository, adopting
  `CreationQuotaProviding`, whose lifetime count the paywall shows.
- `Components/Theme+App.swift` — `Theme.loadingAnimation` and any brand
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
  with `environmentObject`, applies the saved `Appearance` and calls
  `AppBootstrap.configureSentry()`. `AppServices` is the composition root and
  re-broadcasts its children's `objectWillChange`.
- **Logging.** Errors go through `Log` (OSLog plus Sentry), never `print`.
- **Data.** Repositories read with `database.watch` and write to local SQLite;
  PowerSync uploads through `APIConnector`. Deletes are soft (`deleted_at`).
  UUIDs sent to SQLite or the API are lowercased.
- **Concurrency.** `SWIFT_STRICT_CONCURRENCY: complete`. Services and
  repositories are `@MainActor`; justify any `@unchecked Sendable`.
- **Plists.** Info.plist, entitlements and ExportOptions use Xcode's format:
  tab indentation and keys in alphabetical order.
- **Tests.** `Shared*Tests.swift` import whichever app module is present with
  `#if canImport(...)`; add the new module there when adding an app.
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
  `.active` or `hasAccessOverride`, which an app may set from a server-side
  premium flag.
- Transactions are finished only after the server confirms them. StoreKit
  re-delivers an unfinished transaction through `Transaction.updates`, so a
  failed mirror is retried on the next launch. A revoked or expired update is
  finished and followed by an entitlement sync, so access ends in-session.
- The mirror is retried three times (0.5 s, then 1 s) only for connectivity
  and 5xx failures. Client errors, sign-in failures and an inactive verdict
  are final and leave the state `.verifying` with the app's message.
- Sign-out resets the in-memory state, including the override.

Each app's creation-quota gate (server status endpoint, offline quota and
entitlement snapshot, pending-creation ledger and free limit) stays in its
feature folder. Billing only reads the lifetime count through
`CreationQuotaProviding`.

## Adding an app

Copy every file in this manifest, `shared-auth.sha256`, `shared-push-core.sha256`,
`shared-infra.sha256` and `shared-site.sha256` from an existing app, then add the
app's own hooks above, `AGENTS.md`, `README.md` (same section order as the other
apps) and `project.yml`. The site has its own hooks, starting with
`Site/app.json`; see `SHARED_SITE.md`. Add the new module to the `#if canImport`
lists in the shared tests of every app. All five checks must pass before the
first pull request.
