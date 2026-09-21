# Shared APNs gateway migration

This is the canonical execution plan for moving Deadwax Club, Diald, Moss,
and Food to one shared APNs provider. It removes notification delivery from
Supabase Edge Functions without requiring an iCloud account and keeps the
delivery path replaceable when each product later moves away from Supabase.

Read this file first, then follow the linked branch for the work being done:

- [Contract and reference code](REFERENCE_IMPLEMENTATION.md) — read when
  implementing the gateway, an iOS adapter, or a source adapter.
- [Infrastructure runbook](INFRASTRUCTURE.md) — read when provisioning,
  deploying, rotating secrets, or recovering the gateway.
- [Testing and rollout](TESTING_AND_ROLLOUT.md) — read before marking an
  implementation complete or enabling production delivery.
- [Project checklists](PROJECT_CHECKLISTS.md) — read the named project section
  before editing that repository.
- [Primary-source research](../research/shared-apns-gateway.md) — consult when
  an APNs or hosting assumption needs verification.

## Outcome

The permanent delivery path is:

```text
event originator -> source adapter -> PushEvent v1 -> shared gateway -> APNs -> iOS
```

During the migration, a source adapter may be a Supabase Database Webhook and
the identity token may be issued by Supabase Auth. Those are replaceable
adapters. The gateway's domain types, installation registry, queue, APNs
implementation, and iOS interface contain no Supabase types or URLs.

When an app changes backend, replace only its source and identity adapters:

```text
Before: Supabase outbox + Supabase JWT -> stable gateway interfaces
After:  new outbox      + new OIDC JWT -> stable gateway interfaces
```

## Non-negotiable invariants

1. **One installation, one current principal.** Re-registering an installation
   for another signed-in account atomically replaces the old association.
2. **Idempotent events.** `(application_id, event_id)` identifies one logical
   event. Replays return success without creating another APNs delivery.
3. **Canonical history stays upstream.** APNs is delivery, not the notification
   inbox. Deadwax keeps `notifications` as the source of truth until its data
   migration replaces that store.
4. **Provider-neutral interfaces.** Gateway requests use `application_id`,
   `principal_id`, `installation_id`, and `event_id`; names such as
   `supabase_user_id` and Supabase webhook types stay inside source adapters.
5. **No device names.** Store the minimum required registration facts: token,
   topic, environment, installation, principal, and timestamps.
6. **Tokens are replaceable addresses.** Every successful APNs registration is
   sent to the gateway, even if the app believes it has seen the token before.
7. **Logout unbinds before local auth is discarded.** A failed unbind is queued
   for retry and the subsequent registration still replaces the association.
8. **Secrets remain server-side.** APNs `.p8` keys and event-ingress credentials
   never enter an app, repository, xcconfig file, or database row visible to a
   client role.
9. **Explicit environments.** Sandbox and production tokens never share an
   APNs request. The gateway selects both host and signing key by environment.
10. **At-least-once ingress, effectively-once enqueue.** Sources may retry;
    gateway idempotency prevents duplicate queue jobs. APNs itself remains
    best-effort.

## Module seams

### iOS notification module

The app-facing module owns permission state, APNs registration, installation
identity, gateway registration, logout unbinding, and notification routing.
Views and app lifecycle code use this interface:

```swift
@MainActor
protocol PushNotifications: AnyObject {
    var authorizationStatus: UNAuthorizationStatus { get }
    func requestAuthorization() async -> Bool
    func activate() async
    func deactivate() async
    func receivedDeviceToken(_ data: Data) async
    func refreshRegistration() async
}
```

The production adapter calls the gateway. Tests use an in-memory adapter. Apps
that still need rollback support may temporarily retain a legacy Supabase token
adapter behind the same seam; callers do not select or understand the adapter.

Diald's local brew reminders stay inside its notification module but do not
cross the gateway seam.

### Gateway module

The external gateway is a remote-owned dependency. Its small HTTP interface is:

```text
PUT    /v1/apps/{application_id}/installations/{installation_id}
DELETE /v1/apps/{application_id}/installations/{installation_id}/account-link
POST   /v1/apps/{application_id}/events
GET    /health
```

Internally it owns authentication, validation, identity normalization,
idempotency, installation lookup, queueing, APNs JWT caching, retries, invalid
token cleanup, and observability.

### Source adapter

Each originator converts one committed domain event into `PushEvent v1`. A
Supabase adapter may understand the Database Webhook envelope. The gateway core
does not. A future backend adapter can submit the same `PushEvent v1` without
changing either iOS or APNs code.

## Delivery phases

### Phase 0 — Establish the gateway repository

Create `kylescudder/push-gateway` as a standalone TypeScript repository. Use
AWS API Gateway and Lambda for bounded ingress, DynamoDB for registrations and
idempotency, SQS plus a DLQ for durable work, and long-running ECS Fargate
workers for APNs HTTP/2 connection reuse. The exact stack is specified in
[INFRASTRUCTURE.md](INFRASTRUCTURE.md). Its first release must include:

- the four HTTP routes above;
- CDK stacks for application configuration, DynamoDB tables, SQS and its
  dead-letter queue, API Gateway/Lambda ingress, ECS workers, and alarms;
- DynamoDB repositories for installations, events, and deliveries;
- an SQS producer and idempotent consumer with a dead-letter queue;
- APNs token-based authentication and response classification;
- Supabase JWT/JWKS and Supabase Database Webhook adapters isolated under
  `src/adapters/`;
- unit, HTTP/2 protocol integration, infrastructure, and contract tests;
- an operator CLI for registering applications and submitting test events;
- GitHub Actions using AWS workload identity for test, staging deploy, and
  production promotion of the same container digest.

Completion criterion: a sandbox build can register an installation, the CLI can
submit one event twice, exactly one queue job is created, and one notification
arrives on the physical device.

### Phase 1 — Add the iOS adapter without cutting over

In each iOS repository:

1. Add `PUSH_GATEWAY_URL` and `PUSH_GATEWAY_APPLICATION_ID` to the example
   xcconfig, Info.plist generation, and typed secrets/configuration reader.
2. Add a stable installation ID stored in Keychain.
3. Add the HTTP gateway adapter and its injected URLSession seam.
4. Route APNs registration callbacks through the notification module.
5. On sign-in, activate with the current principal and access token; on
   sign-out, deactivate before discarding the session.
6. Register on every launch/foreground after authorization.
7. Keep the legacy upload adapter as fallback while the gateway URL is empty.
8. Add request-shape, lifecycle, account-switch, and disabled-configuration
   tests.

Food follows the same module/configuration shape but does not request user
permission or activate registration yet. User-facing notifications remain out
of scope there; its PR supplies tested readiness for the first feature.

Completion criterion: the project builds with an empty URL, legacy behavior is
unchanged, and a configured debug build registers with the preview gateway.

### Phase 2 — Move source delivery off Edge Functions

Deadwax:

1. Repair the price producer's normalized catalog join.
2. Move new-low notification creation into an `AFTER INSERT` database trigger.
3. Add stable source-event keys and a uniqueness constraint.
4. Add a provider-neutral `push_outbox` table and an `AFTER INSERT` trigger on
   `notifications`.
5. Configure a Database Webhook on `push_outbox` to the gateway's Supabase
   adapter with a per-application ingress credential.
6. Enable the gateway's scheduled Supabase outbox reconciler. The webhook is
   the low-latency path; the reconciler claims expired/unaccepted rows, submits
   them idempotently, and marks acceptance. A webhook alone is not considered
   durable dispatch.

Diald:

- Keep local scheduled reminders local.
- Replace the placeholder `notify-brew-reminder` invocation path with direct
  `PushEvent v1` submission if a server-originated reminder scheduler is
  enabled. Do not create a second remote scheduler merely for this migration.

Moss:

- No remote producer exists today. Migrate installation registration only;
  future trip events must originate through `PushEvent v1`.

Food:

- No producer exists and user-facing push is explicitly out of scope. Do not
  invent one in this migration.

Completion criterion: every active producer reaches the gateway without a
Supabase Edge Function, duplicate source deliveries are idempotent, and the
canonical inbox remains correct when APNs is unavailable.

### Phase 3 — Controlled cutover

1. Deploy preview and configure debug/TestFlight builds first.
2. Verify sandbox and production separately on physical devices.
3. Enable gateway registration for an internal cohort.
4. Route each principal through exactly one visible delivery path.
5. Observe for seven days: registration success, queue age, APNs response
   classes, disabled tokens, duplicate event count, and dead letters.
6. Set the gateway URL for all release builds.
7. Disable notification Edge webhooks/functions, but retain their code for one
   release as rollback material.

Completion criterion: seven consecutive days with no unexpected dead letters,
no duplicate visible deliveries, successful account switching, and acceptable
registration and APNs success rates.

### Phase 4 — Remove Supabase notification delivery infrastructure

Per project, after its minimum supported version contains the gateway adapter:

- remove direct writes to `device_tokens`;
- remove notification-only Edge Functions and deployment instructions;
- remove APNs secrets from Supabase;
- drop `device_tokens` in a later migration after rollback expires;
- update privacy copy to identify the shared provider gateway and APNs;
- retain unrelated IAP Edge Functions;
- retain Deadwax's canonical inbox until its separate data migration.

Completion criterion: repository search finds no notification delivery call to
Supabase, while IAP and unrelated backend features remain intact.

## Pull-request pattern

Every application PR uses:

- branch: `t3code/shared-push-gateway`
- title: `Route push registration through the shared APNs gateway`
- sections: `Summary`, `Project-specific behavior`, `Testing`, `Deployment`,
  `Rollback`
- one checklist copied from [PROJECT_CHECKLISTS.md](PROJECT_CHECKLISTS.md)

Keep infrastructure activation out of application commits: checked-in values
are empty or non-secret identifiers. Environment URLs are supplied by CI or a
developer's ignored xcconfig.

## Definition of complete

The migration is complete only when:

- all active iOS notification registrations go to the gateway;
- active remote producers submit `PushEvent v1` without an Edge Function;
- APNs credentials exist only in gateway secret storage;
- account switching cannot leave one installation subscribed to two accounts;
- sandbox and production have passed the physical-device matrix;
- invalid tokens are disabled from APNs `410` responses;
- duplicate event submission produces one delivery record;
- dead-letter recovery has been exercised;
- every project has a documented rollback;
- changing the origin backend requires only a source/identity adapter change.
