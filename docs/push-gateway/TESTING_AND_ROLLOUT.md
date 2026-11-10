# Testing, acceptance, and rollout

No repository is complete because it compiles. This plan separates deterministic
tests, protocol tests, Apple/device acceptance, and production observation so
failures can be isolated quickly.

## Required evidence per pull request

Every application PR records:

- generated-project command, build command, and test command with result;
- exact unit test classes added and cases covered;
- empty-configuration behavior;
- whether a physical gateway was available, and if not, the named deferred
  acceptance gate;
- files/configuration an operator must supply after merge;
- rollback behavior;
- confirmation that APNs `.p8`, access tokens, service-role keys, and raw device
  tokens are absent from the diff and logs.

Every gateway PR records the image digest, CDK diff, staging endpoint contract
result, queue/DLQ state, and one correlated sandbox event ID.

## iOS deterministic tests

Use `URLProtocol` or an injected `URLSession` protocol abstraction. Never send a
real bearer token from a unit test.

### Configuration

- Empty or missing `PUSH_GATEWAY_URL` produces `nil` configuration and leaves
  current legacy behavior unchanged.
- A malformed URL is disabled rather than crashing.
- Missing application ID is disabled.
- Valid URL and application ID are parsed exactly; trailing slash does not
  create a double slash in requests.
- No secret is required in the app configuration.

### Registration request

Given installation `550d5a6b-7248-49da-a4dc-92db45608c07`, app `deadwaxclub`,
token bytes `[0x00, 0x0a, 0xff]`, and sandbox environment, assert:

```text
PUT /v1/apps/deadwaxclub/installations/550d5a6b-7248-49da-a4dc-92db45608c07
Authorization: Bearer test-access-token
Content-Type: application/json
```

```json
{
  "version": 1,
  "platform": "ios",
  "apns_token": "000aff",
  "apns_environment": "sandbox"
}
```

Assert that the body cannot contain a principal ID, bundle topic, Apple team,
key ID, or Supabase URL. Verify leading-zero token bytes are preserved.

### Unregister request

Assert:

```text
DELETE /v1/apps/deadwaxclub/installations/550d5a6b-7248-49da-a4dc-92db45608c07/account-link
Authorization: Bearer test-access-token
```

No request body or device token is sent. `200...299` succeeds; a non-HTTP
response and non-2xx status are typed failures.

### Installation identity

- First read creates one lowercase UUID and stores it in the Keychain wrapper.
- Subsequent reads return the same UUID.
- Account switch does not replace it.
- Corrupt stored text is replaced by one valid UUID.
- Access failures surface without inventing an unstable in-memory ID.

### Lifecycle state machine

Use spies for identity, installation ID, APNs registration, and transport:

1. APNs token before sign-in is retained but not uploaded.
2. Sign-in after token arrival performs one registration.
3. Sign-in before token arrival waits; token callback performs one registration.
4. Foreground refresh asks iOS to register again when authorization permits.
5. A repeated identical callback is safe and may idempotently register again.
6. Sign-out attempts `DELETE` before auth credentials are discarded.
7. If `DELETE` fails, sign-out continues and a later different-account
   registration rebinds the same installation.
8. Account A to B produces unregister(A), then register(B), never a request
   claiming B with A's token.
9. Denied authorization does not prompt repeatedly or register for remote
   notifications from a background path.
10. An empty gateway URL selects only the legacy adapter; a configured URL
    selects only the gateway adapter. Never invoke both.

### Push routing regression

Existing notification-tap behavior must remain unchanged. For Deadwax, retain
`collection_invite -> openCollection` and `record_id -> openRecord`. For Diald,
retain local brew scheduling. Moss and Food must not gain fabricated routes.

## Application build commands

Use each repository's own instructions. Where `project.yml` is authoritative:

```sh
xcodegen generate
xcodebuild build \
  -project <Project>.xcodeproj \
  -scheme <Scheme> \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO
```

If the project has a test target:

```sh
xcodebuild test \
  -project <Project>.xcodeproj \
  -scheme <Scheme> \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro'
```

CI may use a currently installed simulator rather than the example name. The
PR must record the actual destination. Run `git diff --check` and regenerate the
project after every `project.yml` source/configuration change. Do not commit a
generated project when the repository ignores it.

On non-macOS agent hosts, unit/build commands are an explicit deferred gate,
not silently marked passed. Static checks still include `git diff --check`,
configuration key searches, JSON/plist syntax where applicable, and a review
that every new Swift source is included by the project generator or Xcode
project.

## Source migration tests

Apply the Deadwax migration to a disposable/local Supabase database.

### New-low producer

Seed an album, pressing, record, collection members, list members, and price
entries. Verify:

- a non-low price creates no notification;
- a first and a lower price use the normalized
  `records -> record_pressings -> albums` title/artist join;
- deleted records create no notification;
- collection/list overlap produces one row per user because the audience
  function unions results;
- replay with the same price-entry source key creates no duplicate;
- currency, shop, previous price, and record route survive in payload;
- each notification creates exactly one outbox row;
- historical notifications are not backfilled.

### Existing notification producers

- `invite_to_collection` still commits membership and one canonical inbox row.
- A failed gateway or webhook does not roll back the canonical notification.
- `notifications` stays PowerSync-visible; `push_outbox` is neither in
  PowerSync schema/rules nor the publication.
- Authenticated/anonymous roles cannot read or mutate `push_outbox`.
- The dedicated relay role can select/lease/update outbox rows but cannot read
  profiles, records, auth tables, or insert/delete outbox rows.

### Webhook adapter

Capture an actual Supabase INSERT webhook fixture and assert it normalizes to
the canonical `PushEvent v1`. Reject update/delete events, wrong app credentials,
unknown kinds, oversized fields, invalid UUIDs, and paths whose app ID does not
match configured adapter ownership. Replaying the same outbox event returns the
existing `202` receipt.

Test the scheduled relay independently: concurrent claims never return the
same live lease, a crashed claimant becomes eligible after expiry, retryable
failure advances `next_attempt_at`, permanent validation sets `dead_at`, and
`202` including replay sets `accepted_at`. Disable the webhook in staging and
prove the scheduled reconciler still dispatches the event; then disable the
reconciler and prove the webhook supplies the low-latency path.

## Gateway unit tests

At minimum:

- OIDC signature/issuer/audience/time validation, JWKS cache refresh, unknown
  `kid`, expired token, and cross-app issuer rejection;
- trusted app lookup and rejection of any client attempt to select topic/team;
- canonical-event schema and payload-size boundaries;
- same event/same hash replay and same event/different hash conflict;
- zero/one/many installation fan-out and no cross-principal/app leakage;
- token encryption and redacted logs;
- one principal per installation across account switches;
- APNs ES256 header/claims and provider JWT cache/refresh boundaries;
- response disposition for every documented status/reason;
- an older APNs `410` timestamp cannot disable a newer registration;
- SQS duplicate, lease extension, crash recovery, expiry, max attempts, and DLQ;
- graceful shutdown and backward-compatible payload-version handling.

## APNs protocol integration tests

Use a local TLS HTTP/2 fake APNs server; an HTTP/1.1 mock is insufficient.

- Correlate concurrent streams independently.
- Exercise `200`, permanent `400`, expired-token `403`, invalidating `410`,
  `429`, `500`, and `503` response bodies.
- Exercise stream reset, `GOAWAY`, idle timeout, connection refusal, TLS error,
  and ambiguous disconnect.
- Prove `500`/`503` retries wait at least 15 minutes in policy time (use a fake
  clock; do not sleep in tests).
- Prove sessions and credentials are partitioned by Apple team/environment.
- Prove worker shutdown stops polling and leaves incomplete work recoverable.
- Prove raw tokens, bearer tokens, private keys, and full message bodies are
  absent from captured logs.

## Infrastructure tests

Run `cdk synth` and assertions against the templates:

- staging and production names cannot collide;
- production DynamoDB has PITR and deletion protection;
- queue has encryption, visibility timeout, retention, bounded redrive, and DLQ;
- worker service spans availability zones, minimum count is two in production,
  and rolling health percentages are 100/200;
- IAM roles have no wildcard Secrets Manager/table mutation access;
- only worker/registration roles can decrypt token data;
- API access logs redact authorization;
- queue age, DLQ, auth/5xx, APNs credential, and worker-count alarms exist;
- production workflow consumes a staging-tested image digest.

In staging, stop one worker mid-batch, block APNs egress, create a poison job,
and exercise DLQ redrive and image rollback.

## Apple and physical-device matrix

Apple's Push Notifications Console is the independent oracle. Complete these
steps for every app before production cutover:

1. Inspect the archive's bundle ID and `aps-environment` entitlement.
2. Install on a physical device; grant permission and receive an APNs callback.
3. Validate provider token and captured device token against the exact bundle
   in Apple's console.
4. Send a console notification to isolate Apple/app configuration.
5. Register against gateway staging and submit one canonical event twice.
6. Observe one queue fan-out/delivery record and one visible alert.
7. Correlate gateway `event_id`, `apns-id`, and Apple development delivery logs
   where available.
8. Test foreground, background, terminated-app tap, denied permission, token
   refresh, reinstall, two devices on one account, logout, and account switch.
9. Sign the device out of iCloud and repeat registration/delivery where the
   device permits it. Direct APNs registration uses the app/device APNs token,
   not CloudKit account identity; this is a regression check, not a new app
   requirement.
10. Test TestFlight against production APNs, then perform a release smoke test.

Also force the app offline, create canonical inbox events, and reconnect. The
inbox must recover business state even if an alert expired, collapsed, or was
never displayed.

Food currently has no user-facing push feature or app account. Its Phase 1 PR
does not request permission or run registration. Its device matrix is deferred
until a real user-facing event, identity model, and opt-in UX exist; the PR must
say so explicitly.

## Rollout gates

### Gate A — merged but disabled

- Gateway client is present in all apps.
- Checked-in URL is empty.
- Legacy registration behaves exactly as before.
- Gateway staging and infrastructure tests are green.

### Gate B — debug/internal

- Developer or CI-injected config points debug builds at staging.
- Physical sandbox matrix is complete.
- Source test events use only test principals/tokens.

### Gate C — TestFlight cohort

- Production stack is deployed with production APNs credentials.
- TestFlight uses production APNs.
- Each principal has exactly one visible delivery path.
- Metrics and alerts have named owners.

### Gate D — full client registration

- Registration/error rate is acceptable for the internal cohort.
- Account switch and logout have no cross-account delivery.
- Release config enables the gateway for all users.
- Legacy adapter remains available for one release, inactive when gateway is
  configured.

### Gate E — producer cutover

- Deadwax canonical notification/outbox tests pass.
- Webhook adapter replay/idempotency passes.
- Gateway event path is live before disabling Edge delivery.
- Observe for seven consecutive days with no unexpected DLQ, duplicate visible
  alerts, cross-account delivery, or unexplained queue-age alarm.

### Gate F — cleanup

- Minimum supported app version includes the gateway adapter.
- Remove direct `device_tokens` writes, notification Edge Functions, and their
  Supabase APNs secrets.
- Drop old token storage only after rollback expires.
- Retain unrelated Supabase/IAP infrastructure.

## Stop and rollback conditions

Immediately stop the affected app's cutover for cross-account delivery,
cross-app leakage, widespread APNs `403`, non-empty unexplained DLQ, growing
oldest-job age, duplicate visible alerts, or canonical inbox loss.

Restore the prior single path, roll the gateway image back by digest, and leave
tables/queues intact for diagnosis. Do not flush work or delete installations.
Record event IDs, hashed installation identifiers, timestamps, app/environment,
APNs status/reason, and deployment digest; never copy raw tokens or credentials
into the incident record.
