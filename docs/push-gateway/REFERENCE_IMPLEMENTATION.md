# Contract and reference implementation

This file defines the code shapes shared by all projects. Agents may adapt
namespaces and logging calls, but request fields, lifecycle ordering, and error
semantics are fixed.

## PushEvent v1

`POST /v1/apps/{application_id}/events` accepts the canonical envelope directly. The temporary
Supabase adapter also accepts a Database Webhook envelope whose `record`
contains this shape.

```json
{
  "version": 1,
  "event_id": "2350913f-7bd2-44eb-927b-7f6f6debf348",
  "application_id": "deadwaxclub",
  "occurred_at": "2026-09-20T12:00:00Z",
  "recipients": [
    { "kind": "principal", "id": "lowercase-domain-uuid" }
  ],
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

Rules:

- `event_id` is a UUID and is the idempotency key within `application_id`.
- Recipient IDs are opaque domain principal IDs. The gateway never interprets
  them as Supabase users.
- Custom `data` values are strings. This keeps Swift, JSON, and APNs decoding
  stable.
- `title` is at most 100 characters and `body` at most 500 before enqueue.
- The serialized APNs payload must remain below Apple's regular remote
  notification payload limit.
- `thread_id` controls Notification Center grouping. `collapse_id` controls
  replacement of an undelivered notification and is at most 64 bytes.
- A replay with the same event ID and same payload returns `202`.
- A replay with the same event ID and a different payload returns `409`.

Canonical server producers send the event ID in both body and
`Idempotency-Key`, plus a timestamped HMAC over the exact bytes:

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

Reject timestamps outside five minutes and cache accepted
`(key_id, timestamp, signature)` tuples for that window. The transitional
Supabase Database Webhook cannot generate this signature; for that adapter
only, accept a stage/app-specific bearer secret, compare it in constant time,
require the expected webhook INSERT envelope, and immediately normalize its
`record` to this contract. Neither credential is accepted from an iOS route.

## Installation contract

### Register or rotate

```http
PUT /v1/apps/deadwaxclub/installations/550d5a6b-7248-49da-a4dc-92db45608c07
Authorization: Bearer <current user access token>
Content-Type: application/json
```

```json
{
  "version": 1,
  "platform": "ios",
  "apns_token": "hexadecimal-token",
  "apns_environment": "sandbox"
}
```

The gateway derives `principal_id` from the verified token's `sub` claim. A
client-provided principal is never trusted. The application path selects a
trusted bundle topic, identity issuer allowlist, Apple team, and allowed APNs
environment; the client cannot supply those values. The transaction upserts
the token and atomically rebinds the installation to that principal.

Responses:

- `204`: registered or already current;
- `400`: malformed installation/token/topic/environment;
- `401`: invalid or expired identity token;
- `403`: issuer, audience, application, or topic mismatch;
- `409`: token belongs to a conflicting application;
- `429`/`5xx`: retryable.

### Unbind on logout

```http
DELETE /v1/apps/deadwaxclub/installations/550d5a6b-7248-49da-a4dc-92db45608c07/account-link
Authorization: Bearer <current user access token>
```

The gateway verifies the current principal owns the installation, then sets
`enabled = 0` and clears its principal. It retains the row for audit and future
re-registration.

## iOS reference code

### Configuration

Add non-secret values to each example xcconfig:

```xcconfig
PUSH_GATEWAY_URL =
PUSH_GATEWAY_APPLICATION_ID = deadwaxclub
```

Expose both values through the target Info.plist:

```yaml
PUSH_GATEWAY_URL: $(PUSH_GATEWAY_URL)
PUSH_GATEWAY_APPLICATION_ID: $(PUSH_GATEWAY_APPLICATION_ID)
```

Parse an empty URL as disabled:

```swift
struct PushGatewayConfiguration: Equatable, Sendable {
    let baseURL: URL
    let applicationID: String

    static var fromBundle: PushGatewayConfiguration? {
        guard
            let rawURL = Bundle.main.object(forInfoDictionaryKey: "PUSH_GATEWAY_URL") as? String,
            let baseURL = URL(string: rawURL),
            !rawURL.isEmpty,
            ["https", "http"].contains(baseURL.scheme?.lowercased() ?? ""),
            baseURL.host != nil,
            let applicationID = Bundle.main.object(
                forInfoDictionaryKey: "PUSH_GATEWAY_APPLICATION_ID"
            ) as? String,
            applicationID.range(
                of: #"^[a-z0-9][a-z0-9-]{1,62}[a-z0-9]$"#,
                options: .regularExpression
            ) != nil
        else { return nil }

        return PushGatewayConfiguration(baseURL: baseURL, applicationID: applicationID)
    }
}
```

Never fatal-error on missing gateway configuration. Empty means the gateway
adapter is disabled and the rollout adapter selects legacy behavior.

### Provider-neutral identity seam

```swift
struct PushIdentity: Equatable, Sendable {
    let principalID: String
    let accessToken: String
}

protocol PushIdentityProviding: AnyObject {
    func currentPushIdentity() async -> PushIdentity?
}
```

The temporary Supabase adapter is the only code that imports Supabase:

```swift
extension AuthClient: PushIdentityProviding {
    func currentPushIdentity() async -> PushIdentity? {
        guard
            let principalID = currentUserID?.uuidString.lowercased(),
            let accessToken = await currentAccessToken()
        else { return nil }
        return PushIdentity(principalID: principalID, accessToken: accessToken)
    }
}
```

When auth moves, replace this conformance without editing the notification
module or gateway client.

### Installation ID

Use the project's Keychain wrapper where one exists. The behavior is:

```swift
protocol PushInstallationIDProviding: Sendable {
    func installationID() throws -> UUID
}

struct KeychainPushInstallationIDProvider: PushInstallationIDProviding {
    private let account = "push-gateway.installation-id"

    func installationID() throws -> UUID {
        if let stored = try Keychain.read(account: account),
           let id = UUID(uuidString: stored) {
            return id
        }
        let id = UUID()
        try Keychain.write(id.uuidString.lowercased(), account: account)
        return id
    }
}
```

The ID is per app installation/keychain access group, not per signed-in user.
Account switches rebind it; they do not mint another ID.

### Gateway adapter

```swift
import Foundation

protocol PushRegistrationTransport: Sendable {
    func register(
        installationID: UUID,
        deviceToken: Data,
        environment: APNSEnvironment,
        identity: PushIdentity
    ) async throws

    func unregister(
        installationID: UUID,
        identity: PushIdentity
    ) async throws
}

enum APNSEnvironment: String, Codable, Sendable {
    case sandbox
    case production
}

struct GatewayPushRegistrationTransport: PushRegistrationTransport {
    let configuration: PushGatewayConfiguration
    let session: URLSession

    func register(
        installationID: UUID,
        deviceToken: Data,
        environment: APNSEnvironment,
        identity: PushIdentity
    ) async throws {
        let url = configuration.baseURL
            .appending(path: "v1/apps")
            .appending(path: configuration.applicationID)
            .appending(path: "installations")
            .appending(path: installationID.uuidString.lowercased())
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(identity.accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(RegisterInstallationRequest(
            version: 1,
            platform: "ios",
            apnsToken: deviceToken.hexadecimalString,
            apnsEnvironment: environment
        ))

        let (_, response) = try await session.data(for: request)
        try Self.requireSuccess(response)
    }

    func unregister(
        installationID: UUID,
        identity: PushIdentity
    ) async throws {
        let url = configuration.baseURL
            .appending(path: "v1/apps")
            .appending(path: configuration.applicationID)
            .appending(path: "installations")
            .appending(path: installationID.uuidString.lowercased())
            .appending(path: "account-link")
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(identity.accessToken)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await session.data(for: request)
        try Self.requireSuccess(response)
    }

    private static func requireSuccess(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw PushGatewayError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw PushGatewayError.httpStatus(http.statusCode)
        }
    }
}

private struct RegisterInstallationRequest: Encodable {
    let version: Int
    let platform: String
    let apnsToken: String
    let apnsEnvironment: APNSEnvironment

    enum CodingKeys: String, CodingKey {
        case version
        case platform
        case apnsToken = "apns_token"
        case apnsEnvironment = "apns_environment"
    }
}

enum PushGatewayError: Error, Equatable {
    case invalidResponse
    case httpStatus(Int)
}

private extension Data {
    var hexadecimalString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
```

Production creates `URLSession(configuration: .ephemeral)`. Tests inject a
URLProtocol-backed session and assert the complete request.

### Lifecycle ordering

The notification module retains the most recent APNs token in memory and only
submits when identity and configuration are both available:

```swift
func activate() async {
    identity = await identityProvider.currentPushIdentity()
    await registerLatestTokenIfPossible()
    await registerIfAuthorized()
}

func receivedDeviceToken(_ data: Data) async {
    latestDeviceToken = data
    await registerLatestTokenIfPossible()
}

func deactivate() async {
    guard let identity else { return }
    do {
        try await transport.unregister(
            installationID: installationID,
            identity: identity
        )
    } catch {
        logger(error) // logout continues; next registration atomically rebinds
    }
    self.identity = nil
}
```

The auth owner calls `await notifications.deactivate()` before signing out or
wiping the session. `AppDelegate` forwards the raw `Data`; it does not know
about URLs, auth, or JSON.

All three Supabase-authenticated apps currently expose sign-out on
`AuthClient`, so use one generic pre-invalidation hook rather than trying to
unregister after an auth-state publisher reports `.signedOut`:

```swift
@MainActor
final class AuthClient: ObservableObject {
    var beforeSessionInvalidation: (() async -> Void)?
    var afterSessionInvalidationFailure: (() async -> Void)?

    func signOut() async -> Bool {
        await beforeSessionInvalidation?()
        do {
            try await supabase.auth.signOut()
            return true
        } catch {
            await afterSessionInvalidationFailure?()
            // Preserve each project's existing error reporting and return shape.
            return false
        }
    }

    func deleteAccount() async throws {
        await beforeSessionInvalidation?()
        do {
            try await supabase.rpc("delete_my_account").execute()
            try await supabase.auth.signOut()
        } catch {
            await afterSessionInvalidationFailure?()
            throw error
        }
    }
}
```

Install it once in the composition root:

```swift
auth.beforeSessionInvalidation = { [weak notifications] in
    await notifications?.deactivate()
}
auth.afterSessionInvalidationFailure = { [weak notifications] in
    await notifications?.activate()
}
```

Make the hook idempotent because password-recovery cleanup, account deletion,
and explicit sign-out may converge. Unit tests must assert the unregister call
happens before the fake auth invalidation and that failed invalidation restores
registration. Do not put notification-specific types in `AuthClient`.

### Rollout adapter

While the gateway URL is empty, select the existing registration implementation:

```swift
let registrationTransport: any PushRegistrationTransport
if let configuration = PushGatewayConfiguration.fromBundle {
    registrationTransport = GatewayPushRegistrationTransport(
        configuration: configuration,
        session: URLSession(configuration: .ephemeral)
    )
} else {
    registrationTransport = LegacyPushRegistrationTransport(auth: auth)
}
```

After cutover and rollback expiry, delete the legacy adapter and make a missing
release configuration visible in CI. Do not leave two active transports.

## Deadwax source migration SQL

Use the next sequential migration number. Adapt names only if a newer migration
already occupies it.

```sql
begin;

alter table public.notifications
  add column if not exists source_event_key text;

create unique index if not exists notifications_source_event_unique
  on public.notifications (user_id, source_event_key)
  where source_event_key is not null;

create table if not exists public.push_outbox (
  event_id uuid primary key references public.notifications(id) on delete cascade,
  version integer not null default 1 check (version = 1),
  application_id text not null,
  occurred_at timestamptz not null,
  recipient_principal_id uuid not null,
  notification jsonb not null,
  data jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  accepted_at timestamptz,
  attempt_count integer not null default 0,
  next_attempt_at timestamptz not null default now(),
  lease_until timestamptz,
  last_error text,
  dead_at timestamptz
);

create index if not exists push_outbox_pending_idx
  on public.push_outbox (next_attempt_at, created_at)
  where accepted_at is null and dead_at is null;

alter table public.push_outbox enable row level security;
revoke all on public.push_outbox from anon, authenticated;

create or replace function public.enqueue_notification_for_push()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.push_outbox (
    event_id,
    application_id,
    occurred_at,
    recipient_principal_id,
    notification,
    data
  ) values (
    new.id,
    'deadwaxclub',
    new.created_at,
    new.user_id,
    jsonb_strip_nulls(jsonb_build_object(
      'title', new.title,
      'body', new.body,
      'sound', 'default',
      'thread_id', case
        when new.kind = 'price_alert' then 'record:' || (new.payload->>'record_id')
        when new.kind = 'collection_invite' then 'collection:' || (new.payload->>'collection_id')
      end,
      'collapse_id', case
        when new.kind = 'price_alert' then 'price:' || (new.payload->>'record_id')
        when new.kind = 'collection_invite' then 'collection:' || (new.payload->>'collection_id')
      end
    )),
    jsonb_strip_nulls(new.payload || jsonb_build_object(
      'notification_id', new.id::text,
      'kind', new.kind::text
    ))
  ) on conflict (event_id) do nothing;
  return new;
end;
$$;

drop trigger if exists notifications_enqueue_push on public.notifications;
create trigger notifications_enqueue_push
after insert on public.notifications
for each row execute function public.enqueue_notification_for_push();

create or replace function public.create_new_low_notifications()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_title text;
  v_body text;
begin
  if not new.is_new_low or new.deleted_at is not null then
    return new;
  end if;

  select a.title || ' — ' || a.artist
  into v_title
  from public.records r
  join public.record_pressings rp on rp.id = r.record_pressing_id
  join public.albums a on a.id = rp.album_id
  where r.id = new.record_id and r.deleted_at is null;

  if v_title is null then
    return new;
  end if;

  v_body := case
    when new.previous_min_cents is null then
      'First price logged: ' ||
      to_char(new.price_cents / 100.0, 'FM999999990.00') || ' ' || new.currency
    else
      'New low: ' ||
      to_char(new.price_cents / 100.0, 'FM999999990.00') || ' ' || new.currency ||
      ' (was ' ||
      to_char(new.previous_min_cents / 100.0, 'FM999999990.00') || ' ' || new.currency || ')'
  end;

  if new.shop_name is not null and btrim(new.shop_name) <> '' then
    v_body := v_body || ' at ' || new.shop_name;
  end if;

  insert into public.notifications (
    user_id, kind, title, body, payload, source_event_key
  )
  select
    audience.user_id,
    'price_alert',
    v_title,
    v_body,
    jsonb_strip_nulls(jsonb_build_object(
      'record_id', new.record_id,
      'price_cents', new.price_cents,
      'currency', new.currency,
      'shop_name', new.shop_name,
      'previous_min_cents', new.previous_min_cents
    )),
    'price_entry:' || new.id::text
  from public.notification_audience_for_record(new.record_id) audience
  on conflict (user_id, source_event_key)
    where source_event_key is not null
    do nothing;

  return new;
end;
$$;

drop trigger if exists price_entries_create_new_low_notifications
  on public.price_entries;
create trigger price_entries_create_new_low_notifications
after insert on public.price_entries
for each row execute function public.create_new_low_notifications();

commit;
```

Add `source_event_key` to the PowerSync schema and stream because
`notifications` is synchronized. Do not add `push_outbox` to PowerSync or its
publication.

Before enabling the database webhook, backfill no outbox rows. Only new
notifications should push; historical inbox rows remain history.

The webhook is a low-latency fast path. The temporary gateway source-relay
Lambda in `INFRASTRUCTURE.md` is the durability path: it leases pending rows,
submits the same `event_id` idempotently, and sets `accepted_at` only after the
gateway has durably enqueued the event. Provision its least-privilege database
login outside the migration; never grant that login access to user tables or
store a Supabase service-role key in the gateway.

## Gateway APNs adapter

Use `jose` for ES256 rather than implementing JOSE signature conversion:

```ts
import { importPKCS8, SignJWT } from "jose";

async function providerToken(config: APNsKey): Promise<string> {
  const key = await importPKCS8(config.privateKeyPEM, "ES256");
  return new SignJWT({})
    .setProtectedHeader({ alg: "ES256", kid: config.keyID })
    .setIssuer(config.teamID)
    .setIssuedAt()
    .sign(key);
}
```

Cache one provider token per `(team_id, key_id, environment)` and reuse it for
20–50 minutes. Never let it reach one hour old.

The worker must use a real HTTP/2 client and reuse one session per Apple team
and environment. A per-notification `fetch` is not the reference
implementation.

```ts
import http2, { type ClientHttp2Session } from "node:http2";

function apnsOrigin(environment: APNsEnvironment): string {
  return environment === "production"
    ? "https://api.push.apple.com"
    : "https://api.sandbox.push.apple.com";
}

function openAPNsSession(environment: APNsEnvironment): ClientHttp2Session {
  const session = http2.connect(apnsOrigin(environment));
  session.setTimeout(55_000, () => session.close());
  session.on("goaway", () => session.close());
  session.on("error", error => logger.warn({ error: redact(error) }, "apns session"));
  return session;
}

async function sendToAPNs(
  session: ClientHttp2Session,
  job: DeliveryJob,
  bearer: string,
): Promise<APNsResponse> {
  return new Promise((resolve, reject) => {
    const stream = session.request({
      ":method": "POST",
      ":path": `/3/device/${job.apnsToken}`,
      authorization: `bearer ${bearer}`,
      "apns-topic": job.topic,
      "apns-push-type": "alert",
      "apns-priority": "10",
      "apns-id": job.apnsID,
      ...(job.collapseID ? { "apns-collapse-id": job.collapseID } : {}),
    });
    let status = 0;
    let body = "";
    stream.setEncoding("utf8");
    stream.on("response", headers => { status = Number(headers[":status"]); });
    stream.on("data", chunk => { body += chunk; });
    stream.on("end", () => resolve({ status, body }));
    stream.on("error", reject);
    stream.end(JSON.stringify(buildAPNsPayload(job)));
  });
}
```

The production pool also limits concurrent streams, observes peer settings,
opens a replacement before closing a draining session, and treats ambiguous
stream/connection failures as retryable. Never claim `apns-id` deduplicates a
retry; it is a correlation ID only.

Classify responses:

```ts
function classifyAPNs(status: number, reason?: string): DeliveryDisposition {
  if (status === 200) return "delivered";
  if (status === 410 || reason === "Unregistered") return "disable-installation";
  if (status === 429 || status === 500 || status === 503) return "retry";
  if (status === 403 && reason === "ExpiredProviderToken") return "refresh-token-and-retry";
  return "permanent-failure";
}
```

For `410`, disable the installation only when Apple's invalidation timestamp is
not older than its latest registration. For `500` and `503`, the scheduled
retry is no sooner than Apple's documented 15-minute interval and then uses
bounded exponential backoff. Persist the APNs status/reason but never the raw
device token in logs.

## Gateway persistence

The CDK stack creates three DynamoDB tables. Keep the attribute names and key
layout stable because the API, worker, operator CLI, and alarm dimensions all
depend on them.

```text
Installations
  PK: APP#<application_id>#INSTALLATION#<installation_id>
  application_id, installation_id
  principal_id = <issuer_id>#<subject>
  environment, token_ciphertext, token_hash
  active, registered_at, last_seen_at, invalidated_at
  GSI1PK: APP#<application_id>#PRINCIPAL#<principal_id>
  GSI1SK: INSTALLATION#<installation_id>

EventReceipts
  PK: APP#<application_id>#EVENT#<event_id>
  payload_hash, received_at, state, expires_at (TTL)

Deliveries
  PK: APP#<application_id>#EVENT#<event_id>
  SK: INSTALLATION#<installation_id>
  state, attempt_count, lease_until, apns_id, last_reason
  accepted_at, next_attempt_at, invalidation_timestamp, expires_at (TTL)
```

Registration is one conditional transaction: update the installation and its
principal GSI attributes together. Event ingress uses a conditional
`PutItem(attribute_not_exists(PK))`. If that condition fails, read the receipt:
the same payload hash returns the original `202`; a different hash returns
`409`. Delivery writes use a conditional key so SQS redelivery cannot fan out
the same event twice before checking its existing state.

Encrypt raw tokens with the gateway KMS key before storing them. IAM permits
decryption only to the registration Lambda and worker task role. Logs and
metrics use `token_hash`, never `token_ciphertext`, raw token, bearer token,
notification body, or `.p8` material. APNs private keys and per-application
ingress credentials live in Secrets Manager and are referenced by ARN from
reviewed application configuration.

TTL is retention, not correctness: DynamoDB removes expired records
asynchronously, so every read must reject an expired receipt or delivery even
while the row still exists.
