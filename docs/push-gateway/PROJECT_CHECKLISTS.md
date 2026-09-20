# Project execution checklists

This document is the task brief for application agents. The first pull request
in every repository is **Phase 1 only**: add the shared registration contract
behind disabled configuration, preserve current behavior, and add tests. Do not
enable the URL, deploy infrastructure, remove a token table, or switch a source
producer in these pull requests.

All four PRs use:

```text
branch: t3code/shared-push-gateway
title:  Route push registration through the shared APNs gateway
```

PR bodies use the headings `Summary`, `Project-specific behavior`, `Testing`,
`Deployment`, and `Rollback`. Under Deployment state that checked-in gateway
URLs are empty and activation is gated by the infrastructure/device plan.

## Shared implementation pattern

Use the reference types and wire contract from `REFERENCE_IMPLEMENTATION.md`.
Names may follow the repository, but each authenticated app must end with these
roles:

```text
PushGatewayConfiguration      parses optional URL + stable application ID
PushIdentityProviding         isolates the temporary Supabase auth adapter
PushInstallationIDProviding   returns a Keychain-persisted per-install UUID
PushRegistrationTransport     provider-neutral register/unregister interface
GatewayPushRegistrationTransport
LegacyPushRegistrationTransport
PushManager/NotificationManager
  owns token + lifecycle state and selects exactly one transport
AppDelegate                   only forwards APNs Data/error
AppServices                   activates on sign-in and installs logout hooks
```

Use these exact application IDs:

| Repository | Application ID | Bundle ID |
| --- | --- | --- |
| Deadwax Club | `deadwaxclub` | `com.deadwaxclub.app` |
| Diald Club | `diald` | `club.diald` |
| Moss | `moss` | `app.getmoss.moss` |
| Food | `food` | `org.thescudders.food` |

For Deadwax, Diald, and Moss:

1. Add `PUSH_GATEWAY_URL =` and the application ID to the example xcconfig.
2. Add both build substitutions to `project.yml` and `Info.plist`.
3. Keep an empty/malformed URL disabled; never fatal-error.
4. Persist installation ID under Keychain account
   `push-gateway.installation-id`. Deadwax reuses `Logging/Keychain.swift`;
   Diald and Moss add a minimal Security-backed store in the notification
   module rather than saving the ID in `UserDefaults`.
5. `AuthClient` conforms to `PushIdentityProviding`; no other new type imports
   Supabase.
6. Refactor the current direct token upload into
   `LegacyPushRegistrationTransport` with unchanged table/column semantics.
7. Select gateway when configured, otherwise legacy. Never dual-write.
8. The manager retains raw APNs `Data` in memory, calls its transport only when
   a current identity exists, and re-registers on sign-in and active foreground.
9. Add generic pre-session-invalidation/failure hooks to `AuthClient` exactly
   as described in the reference. Unregister before Supabase invalidates the
   JWT; reactivate if sign-out/account deletion fails.
10. Preserve existing permission UI, notification presentation, tap routes,
    logs, and return values.

If a test cannot safely replace a process singleton, extract the pure state
machine/transport selection into an injected internal type and leave the
singleton as a thin production wrapper. Do not make networking global merely
to avoid that refactor.

Every authenticated-app test target adds:

- `PushGatewayConfigurationTests.swift`;
- `GatewayPushRegistrationTransportTests.swift` using `URLProtocol`;
- `PushRegistrationLifecycleTests.swift` with fake identity, APNs registrar,
  ID store, gateway, and legacy transports.

The minimum cases are listed in `TESTING_AND_ROLLOUT.md`; they are requirements,
not suggestions.

## Deadwax Club

Working tree root for this execution:
`/home/kyle/.t3/worktrees/deadwaxclub/t3code-9ad4ea91`.

### Phase 1 files

- Update `Config/Secrets.xcconfig.example`:

  ```xcconfig
  PUSH_GATEWAY_URL =
  PUSH_GATEWAY_APPLICATION_ID = deadwaxclub
  ```

- Add the two values under the DeadWaxClub target's `info.properties` in
  `project.yml` and to `DeadWaxClub/Info.plist`. Do not add them to the widget.
- Add provider-neutral implementation files under
  `DeadWaxClub/Notifications/`.
- Reuse `DeadWaxClub/Logging/Keychain.swift`; its signatures are
  `read(key:)` and `write(key:value:)`.
- Refactor `DeadWaxClub/Notifications/PushManager.swift`. Preserve
  authorization behavior, `.openCollection`/`.openRecord` tap routing, and
  foreground presentation. Remove `device_name` only from the gateway request;
  legacy fallback must retain its current Supabase payload during rollback.
- Keep `DeadWaxClub/App/AppDelegate.swift` as a forwarding adapter.
- Update `DeadWaxClub/App/AppServices.swift`:
  activate from its signed-in branch; install the two session-invalidation
  hooks after binding auth; keep repository/PowerSync behavior unchanged.
- Update `DeadWaxClub/Auth/AuthClient.swift` with generic hooks and the
  temporary identity conformance. Call hooks in both `signOut()` and
  `deleteAccount()` without changing their public result/error semantics.
- Add tests under `DeadWaxClubTests/`; the target already exists in
  `project.yml`.
- Keep this canonical `docs/push-gateway/` package and its `AGENTS.md` routing
  note in the PR.

### Explicitly not in the Phase 1 PR

- Do not add/enable `push_outbox` yet.
- Do not change `notify-inbox` or `notify-price-change` yet.
- Do not remove `device_tokens` or Supabase APNs secrets.
- Do not touch IAP functions.

### Phase 2 source PR, after staging gateway acceptance

Use the SQL in `REFERENCE_IMPLEMENTATION.md`, but first choose the next free
migration number. In the same PR:

- add `notifications.source_event_key` to
  `DeadWaxClub/Sync/DatabaseSchema.swift` and the notification PowerSync stream;
- do **not** sync or publish `push_outbox`;
- add SQL regression tests/fixtures for new-low, audience overlap,
  normalized album lookup, invitation, idempotency, RLS, and gateway outage;
- deploy the migration before creating the INSERT-only Database Webhook;
- point the webhook at the `deadwaxclub` source-adapter route with its own
  staging secret;
- provision the least-privilege relay database login in secret storage and
  enable the one-minute scheduled outbox reconciler; prove delivery with the
  webhook disabled before calling the producer path durable;
- disable `notify-price-change` only after the trigger is producing canonical
  rows, then disable `notify-inbox` only after outbox delivery is verified;
- update `AGENTS.md` and deployment commands when each function is retired.

The current `notify-price-change` query selects removed `records.title` and
`records.artist`; the replacement must join
`records -> record_pressings -> albums` as shown in the reference SQL.

### Commands

```sh
xcodegen generate
xcodebuild build -project DeadWaxClub.xcodeproj -scheme DeadWaxClub \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
xcodebuild test -project DeadWaxClub.xcodeproj -scheme DeadWaxClub \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro'
git diff --check
```

## Diald Club

Working tree root for this execution:
`/home/kyle/.t3/worktrees/diald/t3code-shared-push-gateway`.

### Phase 1 files

- Read that repository's `AGENTS.md` and `CLAUDE.md` before editing.
- Update `Config/Secrets.xcconfig.example`, `project.yml`, and
  `Diald/Info.plist` with empty URL and `diald` application ID.
- Add shared types under `Diald/Notifications/` and tests under `DialdTests/`.
- Refactor only the remote-registration portion of
  `Diald/Notifications/NotificationManager.swift`. Its
  `BrewReminderSchedule`, persistence, calendar scheduling, cancellation,
  migration from `daily-brew-reminder`, and local notification content must be
  byte-for-byte behaviorally unchanged.
- Move the existing `device_tokens` upsert
  (`user_id, apns_token, device_name, bundle_id, environment`) into the legacy
  adapter; the gateway adapter sends only the shared contract.
- Update `Diald/App/AppServices.swift` signed-in/signed-out lifecycle and
  foreground refresh without disturbing repository/widget refresh.
- Add hooks and identity conformance in `Diald/Auth/AuthClient.swift`, covering
  both `signOut()` and `deleteAccount()`.
- Keep `Diald/App/AppDelegate.swift` a forwarding adapter.
- Add `Docs/SharedPushGateway.md` recording app ID/bundle ID, disabled URL,
  gateway dependency, source status, activation gates, and rollback.

### Producer status

`supabase/functions/notify-brew-reminder/index.ts` is currently a placeholder
that logs recipients and does not send APNs. Leave it untouched in Phase 1.
Do not move local calendar reminders to the gateway and do not create a server
scheduler. If a server-originated reminder feature is later activated, its
source submits `PushEvent v1` and the placeholder function is removed.

### Commands

```sh
xcodegen generate
xcodebuild build -project Diald.xcodeproj -scheme Diald \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
xcodebuild test -project Diald.xcodeproj -scheme Diald \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro'
git diff --check
```

Add regression tests proving every existing local-reminder test still passes
and no local reminder operation calls either remote transport.

## Moss

Working tree root for this execution:
`/home/kyle/.t3/worktrees/moss/t3code-shared-push-gateway`.

### Phase 1 files

- Update `Config/Secrets.xcconfig.example`, `project.yml`, and
  `Moss/Info.plist` with empty URL and `moss` application ID.
- Add shared types under `Moss/Notifications/` and tests under `MossTests/`.
- Refactor `Moss/Notifications/NotificationManager.swift`; move its existing
  `device_tokens(user_id, token, platform)` upsert into the legacy adapter.
  Preserve `deviceToken` publication if Settings relies on it.
- Keep `Moss/App/AppDelegate.swift` as the callback adapter and add the missing
  failed-registration callback so errors use the current `Log` wrapper.
- Update `Moss/App/AppServices.swift`: activate only on signed-in, add an active
  foreground refresh at the view/app lifecycle boundary, and install logout
  hooks without changing trip/profile/PowerSync reset behavior.
- Add hooks and identity conformance in `Moss/Auth/AuthClient.swift`, covering
  `signOut()` and `deleteAccount()`. Keep `PasswordRecoveryCleanup` behavior.
- Add `Docs/SharedPushGateway.md` with the same fields as Diald.

### Producer status

Moss has no remote notification producer. This PR migrates registration only.
Do not create a trip event or Edge Function. A future producer starts directly
with `PushEvent v1` after product requirements define its consent and routing.

### Commands

```sh
xcodegen generate
xcodebuild build -project Moss.xcodeproj -scheme Moss \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
xcodebuild test -project Moss.xcodeproj -scheme Moss \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro'
git diff --check
```

## Food

Working tree root for this execution:
`/home/kyle/.t3/worktrees/food/t3code-shared-push-gateway`.

Food has no application account, remote-notification permission UX, or
user-facing notification producer. Its existing `remote-notification`
background mode and APNs entitlement belong to
`NSPersistentCloudKitContainer`; do not route CloudKit silent notifications
through this gateway.

### Phase 1 readiness files

- The checked-in Xcode project is authoritative. Add empty
  `PUSH_GATEWAY_URL` and `PUSH_GATEWAY_APPLICATION_ID = food` user-defined build
  settings to both Food app configurations, expose them in
  `Food/App/Info.plist`, and do not add them to FoodTests.
- Add the same pure provider-neutral contract/configuration,
  `GatewayPushRegistrationTransport`, and Security-backed installation ID
  provider under `Food/Notifications/`.
- Add `FoodTests/PushGatewayConfigurationTests.swift` and
  `FoodTests/GatewayPushRegistrationTransportTests.swift`, and add every new
  source/test file to `Food.xcodeproj/project.pbxproj`.
- Add `Docs/SharedPushGateway.md` stating that runtime activation is blocked on
  a real user-facing notification feature, account/identity model, consent UX,
  source event, and completed device matrix.

### Explicitly forbidden in this PR

- Do not instantiate a notification manager.
- Do not call `requestAuthorization` or `registerForRemoteNotifications`.
- Do not intercept or alter CloudKit remote notification callbacks.
- Do not add Supabase, another identity SDK, an event producer, or a server.
- Do not claim Food works without iCloud for its existing household sharing;
  only the future direct APNs gateway is independent of iCloud identity.

This intentionally lands a tested compatibility seam, not dead runtime
behavior. When Food gains a real feature, its product PR supplies identity,
manager lifecycle, permission copy, routing, gateway configuration, and the
physical-device matrix together.

### Commands

```sh
xcodebuild build -project Food.xcodeproj -scheme Food \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
xcodebuild test -project Food.xcodeproj -scheme Food \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro'
plutil -lint Food/App/Info.plist Food/Food.entitlements
git diff --check
```

## Cross-repository review before opening PRs

The coordinating agent compares all four diffs together:

- same endpoint paths, JSON keys, status policy, token hex encoding, app-ID
  validation, Keychain account, and environment enum;
- app-specific values exactly match the table above;
- empty URL everywhere; no committed host or credential;
- authenticated apps select one transport and unbind before token invalidation;
- Food contains no runtime activation;
- no producer or database migration accidentally included;
- docs, test names, branch, PR title, and PR body headings match.

Only after this review should branches be pushed and PRs opened.
