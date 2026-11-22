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
Site/                      Astro marketing, support and legal site
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
<App>/Billing/             BillingRepository, SubscriptionPaywallView
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

## Adding an app

Copy every file in this manifest, `shared-auth.sha256`, `shared-push-core.sha256`
and `shared-infra.sha256` from an existing app, then add the app's own hooks
above, `AGENTS.md`, `README.md` (same section order as the other apps) and
`project.yml`. Add the new module to the `#if canImport` lists in the shared
tests of every app. All four checks must pass before the first pull request.
