# Shared APNs gateway

Deadwax Club, Diald and the other iOS apps share one APNs provider: a small
authenticated gateway that owns device installations, queues notifications and
delivers them to Apple over HTTP/2. This document defines the contract the app
and the Deadwax API follow. The platform research behind it is in
[research/shared-apns-gateway.md](research/shared-apns-gateway.md).

```text
domain event -> PushEvent v1 -> shared gateway -> APNs -> iOS
```

The gateway is a separate service; this repository contains only its clients.

## Registration path in the app

The app's notification module owns permission state, APNs registration,
installation identity, account linking, logout unbinding and notification
routing. Views and lifecycle code see one interface:

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

The transport is selected from `Config/Secrets.xcconfig`:

- `PUSH_GATEWAY_URL` empty: register the device with the Deadwax API
  (`POST /api/devices`, unbind with `DELETE /api/devices`). The API stores
  owner-scoped rows in `device_tokens`.
- `PUSH_GATEWAY_URL` set: register the installation with the gateway
  (`PUT …/installations/{installation_id}`).

Exactly one transport is active; the app never writes to both.
`PUSH_GATEWAY_APPLICATION_ID` is `deadwaxclub` in every environment.

Lifecycle rules:

- The module keeps the latest APNs token in memory and registers only when both
  an identity and a configuration are available. Every successful APNs
  registration is sent again, even if the token looks unchanged.
- `AuthClient` calls the module's `deactivate()` through a
  `beforeSessionInvalidation` hook before sign-out or account deletion, and
  `activate()` through `afterSessionInvalidationFailure` if invalidation fails.
  The hook is idempotent. `AuthClient` holds no notification types.
- A failed unbind does not block sign-out; the next registration atomically
  rebinds the installation.
- `AppDelegate` forwards the raw token `Data` and knows nothing about URLs, auth
  or JSON.

## Invariants

1. **One installation, one current principal.** Registering an installation for
   another account atomically replaces the previous association.
2. **Idempotent events.** `(application_id, event_id)` identifies one logical
   event. A replay with the same payload returns `202`; one with a different
   payload returns `409`.
3. **The inbox is canonical.** APNs is best-effort delivery. Deadwax keeps
   `public.notifications` as the source of truth, and notification taps open
   that state.
4. **Provider-neutral contract.** Requests use `application_id`,
   `principal_id`, `installation_id` and `event_id` only.
5. **Minimal data.** Store the token, topic, environment, installation,
   principal and timestamps; no device names.
6. **Secrets stay server-side.** APNs `.p8` keys and event-ingress credentials
   never reach an app, repository, xcconfig file or client-visible row.
7. **Explicit environments.** Sandbox and production tokens never share a
   request; the gateway selects host and signing key by environment.
8. **At-least-once ingress, effectively-once enqueue.** Producers may retry;
   gateway idempotency prevents duplicate deliveries.

## HTTP contract

```text
PUT    /v1/apps/{application_id}/installations/{installation_id}
DELETE /v1/apps/{application_id}/installations/{installation_id}/account-link
POST   /v1/apps/{application_id}/events
GET    /health
```

### Register or rotate an installation

```http
PUT /v1/apps/deadwaxclub/installations/550d5a6b-7248-49da-a4dc-92db45608c07
Authorization: Bearer <current Better Auth session token>
Content-Type: application/json

{ "version": 1, "platform": "ios", "apns_token": "<lowercase hex>", "apns_environment": "sandbox" }
```

The gateway verifies the bearer token against the Deadwax API and derives
`principal_id` from it; a client-supplied principal is never trusted. The
application path selects the trusted bundle topic (`com.deadwaxclub.app`),
Apple team and allowed environments. The installation ID is a Keychain-backed
lowercase UUID.

Responses: `204` registered or already current; `400` malformed input; `401`
invalid or expired session; `403` application or topic mismatch; `409` token
owned by another application; `429`/`5xx` retryable.

### Unbind on logout

```http
DELETE /v1/apps/deadwaxclub/installations/550d5a6b-7248-49da-a4dc-92db45608c07/account-link
Authorization: Bearer <current Better Auth session token>
```

The gateway checks that the caller owns the installation, disables it and clears
its principal, keeping the row for later re-registration.

### PushEvent v1

```json
{
  "version": 1,
  "event_id": "2350913f-7bd2-44eb-927b-7f6f6debf348",
  "application_id": "deadwaxclub",
  "occurred_at": "2026-09-20T12:00:00Z",
  "recipients": [{ "kind": "principal", "id": "lowercase-user-uuid" }],
  "notification": {
    "title": "Album — Artist",
    "body": "New low: 12.99 GBP",
    "sound": "default",
    "thread_id": "record:lowercase-record-uuid",
    "collapse_id": "price:lowercase-record-uuid"
  },
  "data": {
    "notification_id": "2350913f-7bd2-44eb-927b-7f6f6debf348",
    "kind": "price_alert",
    "record_id": "lowercase-record-uuid"
  }
}
```

- `event_id` is a UUID and the idempotency key within the application.
- Recipient IDs are opaque Deadwax user UUIDs.
- `data` values are strings. `title` is at most 100 characters and `body` at
  most 500. `collapse_id` is at most 64 bytes, and the APNs payload stays under
  Apple's limit.
- Deadwax sends one event per `public.notifications` row. The current kinds are
  `price_alert` (a new low on a wishlist record) and `collection_invite`. The
  app routes taps by `kind`, falling back to `record_id`.

Producers authenticate with a per-application HMAC over the exact bytes:

```http
POST /v1/apps/deadwaxclub/events
Authorization: Push-HMAC key_id="deadwax-primary",signature="<base64url>"
X-Push-Timestamp: 1789905600
Idempotency-Key: 2350913f-7bd2-44eb-927b-7f6f6debf348
Content-Type: application/json
```

```text
canonical = METHOD + "\n" + PATH + "\n" + TIMESTAMP + "\n" + SHA256(BODY)
signature = BASE64URL(HMAC_SHA256(per_app_secret, canonical))
```

The gateway rejects timestamps more than five minutes old and replays of an
accepted `(key_id, timestamp, signature)` within that window. Event credentials
are never accepted from an iOS route.

## Gateway delivery

- Provider tokens are ES256 JWTs cached per `(team_id, key_id, environment)`
  and refreshed well before one hour.
- Workers hold one reusable HTTP/2 session per Apple team and environment.
- `410 Unregistered` and `400 BadDeviceToken` disable the installation. `429`
  and `5xx` retry with backoff, up to a bounded number of attempts, then go to a
  dead-letter queue.

## Testing

- **iOS unit tests** (`DeadWaxClubTests`) cover:
  - configuration parsing;
  - the register and unregister request shapes, including leading-zero token bytes;
  - installation-ID persistence;
  - lifecycle ordering: unregister happens before session invalidation, and a
    failed invalidation restores registration;
  - transport selection;
  - notification tap routing.
- **Physical-device checks:** sandbox and TestFlight (production APNs)
  delivery; logout; failed logout; account switch; token refresh; two devices;
  denied permission; background and terminated delivery.
