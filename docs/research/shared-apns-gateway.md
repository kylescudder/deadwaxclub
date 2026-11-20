# Shared APNs gateway research

Date: 2026-09-20

## Purpose

This note records the platform facts and infrastructure constraints for a provider-neutral push gateway shared by multiple iOS applications. It deliberately does not describe migrations for any particular application repository.

The recommended shape is a small authenticated API, a durable installation registry, a durable at-least-once queue, and long-running workers that hold HTTP/2 connections to Apple Push Notification service (APNs). This path has no CloudKit or iCloud-account dependency. Each application's current backend can submit events during migration; a later backend can use the same HTTP contract.

## Conclusions

1. Use direct APNs, not CloudKit subscriptions. Direct APNs addresses an app installation with an app-specific device token and does not use a person's CloudKit database or iCloud identity. Apple's registration prerequisites are the Push Notifications capability, a correctly signed `aps-environment` entitlement, and APNs/network availability. Apple does not state the sentence "APNs works without an iCloud account" verbatim, so this conclusion is an architectural inference from the documented APNs protocol rather than a quotation. See [Registering your app with APNs](https://developer.apple.com/documentation/usernotifications/registering-your-app-with-apns) and [`aps-environment`](https://developer.apple.com/documentation/bundleresources/entitlements/aps-environment).
2. A single service can support many apps. It must partition configuration and HTTP/2 connection pools by Apple developer team and environment, and always use the correct app bundle ID as `apns-topic`. Apple does not support authentication tokens from different developer accounts over one connection. See [Establishing a token-based connection to APNs](https://developer.apple.com/documentation/usernotifications/establishing-a-token-based-connection-to-apns).
3. Push is a best-effort signal, not an authoritative inbox. APNs may throttle, store, discard, reorder, or overwrite pending notifications. Keep canonical notification/event state in an application-owned store and make notification taps fetch or open that state. See [Sending notification requests to APNs](https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns) and [Viewing push status](https://developer.apple.com/documentation/usernotifications/viewing-the-status-of-push-notifications-using-metrics-and-apns).
4. The recommended production host is AWS: API Gateway/Lambda for stateless ingress, DynamoDB for the installation and delivery registry, SQS plus a dead-letter queue for durable work, Secrets Manager for `.p8` keys, and an ECS Fargate worker for reusable HTTP/2 connections. This is more infrastructure than a single container, but the durability, connection lifetime, failure isolation, and scaling model are explicit.
5. Fly.io is a viable lower-complexity alternative when paired with Managed Postgres and an application-managed outbox/queue. Cloudflare Queues is a viable queue, but a Cloudflare Worker is not currently a suitable APNs sender: Cloudflare documents `node:http2` as a non-functional stub, while Apple requires HTTP/2. A Worker/Queue frontend would still need an external pull consumer that owns the APNs connections. See [Cloudflare Node.js compatibility](https://developers.cloudflare.com/workers/runtime-apis/nodejs/) and [Cloudflare Queues pull consumers](https://developers.cloudflare.com/queues/configuration/pull-consumers/).

## APNs client lifecycle

### Permission and registration are distinct

An app requests permission for visible interactions using `UNUserNotificationCenter.requestAuthorization`. The person may later change alert, badge, or sound settings, so the app should read `notificationSettings()` when presenting status. Apple recommends asking in context rather than automatically at first launch. See [Asking permission to use notifications](https://developer.apple.com/documentation/usernotifications/asking-permission-to-use-notifications).

The app calls `UIApplication.registerForRemoteNotifications()` to register with APNs. On success, iOS calls `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`; on failure it calls `application(_:didFailToRegisterForRemoteNotificationsWithError:)`. Apple directs apps to register on launch, securely forward every returned token to the provider, and retry a failed registration later. See [Registering your app with APNs](https://developer.apple.com/documentation/usernotifications/registering-your-app-with-apns).

The implementation baseline is:

```swift
import UIKit
import UserNotifications

@MainActor
func enableNotifications() async throws {
    let center = UNUserNotificationCenter.current()
    _ = try await center.requestAuthorization(options: [.alert, .badge, .sound])
    UIApplication.shared.registerForRemoteNotifications()
}

func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
) {
    // Preserve leading zeroes: two lowercase hex digits per byte.
    let token = deviceToken.map { String(format: "%02x", $0) }.joined()
    Task { await notificationGateway.registerCurrentInstallation(apnsToken: token) }
}

func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
) {
    notificationGateway.noteAPNsRegistrationFailure(error)
}
```

The app should not infer the token's environment from its bytes. The signed `aps-environment` entitlement determines whether registration is development or production. Development provisioning uses sandbox; distribution, prerelease, and TestFlight builds use production. See [`aps-environment`](https://developer.apple.com/documentation/bundleresources/entitlements/aps-environment).

### Token rules

- A token identifies one app-device combination. It cannot be reused by another app, even on the same device.
- Never assume a fixed token size and never cache the token as if it were permanent. Apple says tokens can change periodically and after device restore, use on a new device, or OS reinstall.
- Upload the token on every successful callback. If unchanged, the gateway upsert is cheap and idempotent.
- One account can have several devices/tokens. One physical installation can also change signed-in accounts. On sign-out, unlink that installation from the old account; do not merely wait for the token to expire.
- Store a separate random installation ID in Keychain. The APNs token is an address, not an installation identity or authentication credential.

These requirements come from [Registering your app with APNs](https://developer.apple.com/documentation/usernotifications/registering-your-app-with-apns) and [`didRegisterForRemoteNotificationsWithDeviceToken`](https://developer.apple.com/documentation/uikit/uiapplicationdelegate/application(_:didregisterforremotenotificationswithdevicetoken:)). The Keychain installation ID and sign-out behavior are gateway design requirements, not Apple protocol requirements.

## Provider authentication and connection partitioning

Use APNs token authentication rather than per-app provider certificates. Apple states that a provider token can be used from multiple provider servers and can distribute notifications for all or a subset of a company's apps. Token-authenticated requests support all APNs push types. See [Establishing a token-based connection to APNs](https://developer.apple.com/documentation/usernotifications/establishing-a-token-based-connection-to-apns).

The provider JWT has this form:

```json
// JOSE header
{ "alg": "ES256", "kid": "ABC123DEFG" }

// Claims
{ "iss": "DEF123GHIJ", "iat": 1789891200 }
```

- `kid` is the 10-character APNs key ID.
- `iss` is the 10-character Apple developer Team ID.
- `iat` is UTC Unix epoch seconds.
- Sign with the server-only `.p8` key using ES256.
- Send it as `authorization: bearer <jwt>`.
- Cache and reuse JWTs. Apple requires refresh no more often than every 20 minutes and at least once every 60 minutes. A token older than one hour receives `403 ExpiredProviderToken`; minting too frequently can receive `429 TooManyProviderTokenUpdates`.

Current Apple key scopes matter:

- Team-scoped keys apply to all existing and new topics for one developer team, but newly created keys are restricted to Sandbox or Production. Older keys valid in both environments remain supported. Apple allows up to two team-scoped keys per environment.
- Topic-specific keys cover selected topics in one environment.
- APNs associates a connection with its team, environment/key relationship, and topics on the first valid push. It does not support multiple developer accounts on one connection.
- Open a new connection when adding a topic, transferring an app, changing the relevant key relationship, or revoking/replacing a key.

Accordingly, the safe pool key is at least:

```text
(appleTeamID, apnsEnvironment, apnsKeyID/keyScope)
```

Each request separately supplies `apns-topic = bundleID`. Do not allow a submitted event to choose arbitrary team, environment, topic, or secret references; resolve those from trusted per-application gateway configuration.

Apple requires an Account Holder or Admin to create the `.p8` key. See [Create a private key](https://developer.apple.com/help/account/keys/create-a-private-key).

## APNs HTTP/2 contract

Apple requires HTTP/2 over TLS 1.2 or later:

- Sandbox: `api.sandbox.push.apple.com:443`
- Production: `api.push.apple.com:443`
- Port `2197` is also supported when a firewall needs an APNs-specific egress rule.
- Request path: `POST /3/device/<hex-device-token>`

A normal visible notification request is:

```http
POST /3/device/0123abcd... HTTP/2
host: api.push.apple.com
authorization: bearer <cached-provider-jwt>
apns-topic: com.example.application
apns-push-type: alert
apns-id: 7c55e52e-5078-42b6-9f0f-cf5f7b3d43f8
apns-expiration: 1789894800
apns-priority: 10
apns-collapse-id: price-record-123
content-type: application/json

{
  "aps": {
    "alert": {
      "title": "Price update",
      "body": "An item has a new low price."
    },
    "sound": "default",
    "thread-id": "price-alerts",
    "category": "PRICE_ALERT"
  },
  "schema_version": 1,
  "event_id": "7c55e52e-5078-42b6-9f0f-cf5f7b3d43f8",
  "route": { "kind": "record", "id": "123" }
}
```

Header semantics:

- `apns-id` is a canonical UUID for tracing. If omitted, APNs generates one. Apple does not document it as an idempotency key.
- `apns-topic` is generally the target app's bundle ID for alert/background pushes.
- `apns-push-type` should match the payload. Use `alert` for a visible alert; use `background` with priority `5` for a silent update.
- `apns-expiration` is a Unix timestamp. `0` asks APNs not to store the notification. A nonzero value permits best-effort storage/retry until that time; omission uses Apple's storage policy.
- `apns-priority` `10` requests immediate alert delivery; use `5` when immediate action is unnecessary. Background pushes must use `5`.
- `apns-collapse-id`, at most 64 bytes, tells APNs to merge replaceable notifications. It is not a general exactly-once mechanism.
- Payload `aps.thread-id` groups related visible notifications in the UI. It is independent of collapse behavior.

Apple limits normal remote-notification payloads to 4,096 bytes of uncompressed JSON. Custom values must be JSON primitive/array/dictionary values. Apple warns against putting sensitive customer data in a payload unless encrypted or useless outside the app. Prefer opaque event and route identifiers plus generic display text where practical. See [Generating a remote notification](https://developer.apple.com/documentation/usernotifications/generating-a-remote-notification).

### Connection behavior

Maintain long-lived sessions and concurrent streams. Apple does not publish a fixed stream limit; it varies with load and authentication state. Do not repeatedly open and close connections, because Apple may treat that behavior as a denial-of-service pattern. Handle HTTP/2 `GOAWAY`, then establish a replacement pool connection. After an hour of inactivity a provider may send an HTTP/2 `PING`. See [Sending notification requests to APNs](https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns) and [Establishing a connection to APNs](https://developer.apple.com/documentation/usernotifications/establishing-a-connection-to-apns).

The worker must drain every response body and correlate it with the request stream. A `200` means APNs accepted the request, not that the notification was displayed.

## Response handling and retry policy

APNs returns an HTTP response for every request. Errors have a JSON `reason`; a `410` also has a millisecond epoch `timestamp` describing when APNs confirmed that token was no longer valid for the topic. Apple's complete list is in [Handling notification responses from APNs](https://developer.apple.com/documentation/usernotifications/handling-notification-responses-from-apns).

| APNs result | Gateway action |
| --- | --- |
| `200` | Record accepted time and returned `apns-id`; delete/ack the queue job. Do not claim delivery. |
| `410 ExpiredToken` or `Unregistered` | Atomically deactivate the exact `(app, environment, topic, token)` registration and ack. If the app later uploads the same token, reactivate it as a newer registration. |
| `400 BadDeviceToken` | Do not retry. Quarantine/deactivate the exact registration and alert on environment/config mismatches. |
| `400 DeviceTokenNotForTopic` | Do not retry. Quarantine the registration and alert because app/topic association is wrong. |
| `400` request-shape errors, `404`, `405`, `413 PayloadTooLarge` | Permanent for this job. Send to a terminal-failure store/DLQ and alert; fix the producer or gateway before replay. |
| `403 ExpiredProviderToken` | Refresh the cached JWT once and retry. Repeated failure is operational/configuration failure. |
| Other `403` auth/key/topic errors | Do not loop. Open a circuit for that app/pool, retain work, and alert for operator repair. `Forbidden` is explicitly non-retryable without a fix. |
| `429 TooManyRequests` | Retry with a delay and jitter; reduce per-token concurrency. |
| `429 TooManyProviderTokenUpdates` | Stop minting per request, reuse the cached JWT, and retry after correcting token refresh behavior. |
| `500`, `503` | Apple says retry after 15 minutes and permits backoff. Retain the queue job and retry with jitter. |
| HTTP/2 `GOAWAY`, `IdleTimeout`, transport loss before a response | Replace the connection and retry with backoff. Acceptance can be ambiguous after transport loss, so duplicates remain possible. |

Apple's current APNs response documentation does not specify a `Retry-After` response header. Do not write an implementation that depends on one.

For `410`, compare the APNs invalidation timestamp with the registry's token registration time before deactivating. This prevents an old in-flight response from disabling a token that the app re-uploaded later. The comparison is an implementation inference based on the timestamp semantics Apple documents.

At-least-once queues and ambiguous HTTP failures make absolute exactly-once visual notifications impossible. Use all three mitigations:

1. A stable producer `event_id` and conditional idempotency record.
2. A deterministic `apns-id` and, for replaceable alerts, a semantic `apns-collapse-id`.
3. Event/inbox deduplication in the app when it opens or refreshes canonical state.

Do not claim that APNs deduplicates repeated `apns-id` values; Apple documents that header for correlation only.

## Provider-neutral gateway contract

The permanent contract must not contain Supabase webhook shapes, PostgREST semantics, PowerSync types, or database credentials.

### Installation registration

```http
PUT /v1/apps/deadwax/installations/7aa7f090-7ad3-4a43-849a-b50f9a10f772
Authorization: Bearer <app-user-access-token>
Content-Type: application/json

{
  "schema_version": 1,
  "platform": "ios",
  "apns_environment": "production",
  "device_token": "0123abcd...",
  "build": "217",
  "locale": "en-GB"
}
```

The API derives the external subject and issuer from the verified access token. It derives the bundle ID/topic and allowed environment from trusted app configuration. It returns `204` for a successful idempotent upsert.

On account sign-out:

```http
DELETE /v1/apps/deadwax/installations/7aa7f090-7ad3-4a43-849a-b50f9a10f772/account-link
Authorization: Bearer <old-account-access-token>
```

Deleting the account link need not delete the installation itself; a later sign-in can relink the same installation and current APNs token. An uninstall cannot call the API, so APNs `410` is the eventual cleanup path.

Authentication must be implemented as an issuer adapter configured per app. The gateway's canonical principal can be:

```text
app_id + issuer_id + subject
```

If an application later changes identity providers, link the old and new subjects to a stable application-domain account ID during authenticated migration. A Supabase user UUID can be an opaque transitional subject, but the gateway must not validate it by calling Supabase or assume Supabase-specific JWT claims.

AWS API Gateway JWT authorizers validate issuer, audience, time claims, signature, and scopes, but AWS currently documents only RSA algorithms for that authorizer. Use it only where every configured issuer is compatible; otherwise use a Lambda authorizer or verify standards-compliant JWTs in the registration service. See [API Gateway JWT authorizers](https://docs.aws.amazon.com/apigateway/latest/developerguide/http-api-jwt-authorizer.html).

### Backend event submission

```http
POST /v1/apps/deadwax/events
Authorization: Signature <server-credential-and-signature>
Idempotency-Key: 7c55e52e-5078-42b6-9f0f-cf5f7b3d43f8
Content-Type: application/json

{
  "schema_version": 1,
  "event_id": "7c55e52e-5078-42b6-9f0f-cf5f7b3d43f8",
  "recipient": { "account_id": "domain-account-123" },
  "notification": {
    "kind": "price_alert",
    "title": "Price update",
    "body": "An item has a new low price.",
    "thread_id": "price-alerts",
    "collapse_id": "price-record-123"
  },
  "route": { "kind": "record", "id": "123" },
  "expires_at": "2026-09-21T12:00:00Z"
}
```

Producer credentials are server-only. Never embed a shared producer secret in an iOS binary. Use per-app credentials so one compromised backend cannot submit for another app. Acceptable mechanisms include mTLS, a service JWT signed by a per-app key, AWS IAM/SigV4 for co-located producers, or an HMAC canonical-request scheme with timestamp and replay protection.

The gateway validates the app/kind payload against an allowlist and enforces maximum lengths before enqueueing. It resolves app ID to trusted APNs config; producer input never supplies bundle ID, Team ID, key ID, environment host, or secret ARN.

## Recommended AWS deployment

### Components

```text
iOS app
  -> API Gateway HTTP API
  -> registration Lambda
  -> DynamoDB Installations

application backend
  -> API Gateway HTTP API
  -> event-ingress Lambda
  -> SQS PushJobs -> SQS PushJobsDLQ
                      |
                      v
              ECS Fargate APNs workers
                -> DynamoDB registry/delivery state
                -> Secrets Manager APNs keys
                -> APNs HTTP/2 pools
```

Why this split:

- Lambda is a good fit for bounded, stateless validation/upsert/enqueue operations.
- Fargate workers are long-lived, so they can reuse APNs HTTP/2 connections and cached JWTs. Run at least two tasks across availability zones in production.
- Standard SQS is durable and at-least-once. AWS explicitly requires idempotent consumers because duplicates are possible. Configure a visibility timeout longer than normal processing, extend it while necessary, and attach a DLQ. See [SQS at-least-once delivery](https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/standard-queues-at-least-once-delivery.html) and [SQS visibility timeout](https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-visibility-timeout.html).
- DynamoDB conditional writes (`attribute_not_exists`) provide event and delivery idempotency guards. TTL can age out old delivery records, but deletion is asynchronous and expired items must be filtered until removed. See [DynamoDB `PutItem`](https://docs.aws.amazon.com/amazondynamodb/latest/APIReference/API_PutItem.html) and [DynamoDB TTL](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/TTL.html).
- Secrets Manager supplies APNs private keys to only the worker task role. ECS supports injecting Secrets Manager values through task definitions, although fetching through the SDK can reduce accidental environment exposure. See [Secrets in ECS](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/specifying-sensitive-data-tutorial.html).

Minimum DynamoDB data model:

```text
Installations
  PK: APP#<app_id>#INSTALLATION#<installation_id>
  app_id, installation_id, principal_id, environment, token_ciphertext,
  token_hash, registered_at, last_seen_at, active, invalidated_at
  GSI1PK: APP#<app_id>#PRINCIPAL#<principal_id>
  GSI1SK: INSTALLATION#<installation_id>

EventReceipts
  PK: APP#<app_id>#EVENT#<event_id>
  payload_hash, received_at, status, expires_at (TTL)

Deliveries
  PK: APP#<app_id>#EVENT#<event_id>
  SK: INSTALLATION#<installation_id>
  state, attempt_count, lease_until, apns_id, last_reason,
  accepted_at, next_attempt_at, expires_at (TTL)
```

Encrypt raw device tokens at the application layer or tightly restrict the DynamoDB KMS key and IAM policies. Never log raw APNs tokens, bearer tokens, `.p8` contents, or complete notification bodies. A token hash is sufficient for correlation metrics.

### Infrastructure as code and release method

Provision the stack with AWS CDK/CloudFormation in a dedicated gateway repository and AWS account/environment:

1. `GatewayDataStack`: DynamoDB tables and KMS key.
2. `GatewayQueueStack`: primary SQS queue, DLQ, redrive policy, retention, alarms.
3. `GatewayIngressStack`: HTTP API, Lambda integrations/authorizers, WAF/rate limits as required, custom domain.
4. `GatewayWorkerStack`: ECR repository, ECS cluster, Fargate service, task roles, security groups, logs, Secrets Manager references, autoscaling.
5. `GatewayObservabilityStack`: CloudWatch dashboards and alarms for queue age/depth, DLQ count, APNs response classes/reasons, inactive-token rate, worker restarts, auth failures, and notification latency.

Operational commands should be predictable and environment-qualified:

```sh
npm ci
npm test
npm run build
npx cdk synth -c stage=staging
npx cdk diff -c stage=staging
npx cdk deploy --all -c stage=staging

# Promote the same tested image digest/config to production.
npx cdk diff -c stage=production
npx cdk deploy --all -c stage=production
```

Create/import APNs secrets separately from CloudFormation so secret material is never committed or embedded in synthesized templates. Reference secret ARNs from the stack. Restrict deployment credentials through CI workload identity and separate staging/production roles.

Set ECS rolling deployment minimum healthy percentage to 100% and maximum to 200% so replacement workers start before old ones stop. Drain workers on `SIGTERM`: stop polling, extend visibility for active jobs if necessary, wait for in-flight APNs streams, then close sessions. AWS documents how these percentages preserve task availability during rolling replacement. See [ECS service deployment parameters](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/update-service-parameters.html).

Scale on SQS backlog per running task, not raw queue depth. AWS recommends backlog-per-task target tracking and task scale-in protection during active work. Keep a minimum of two production workers so connections stay warm and one task loss does not pause delivery. See [Scaling ECS from SQS](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/service-autoscaling-queue.html).

### Environment separation

Use separate AWS staging and production stacks and preferably separate AWS accounts. The staging application may use APNs sandbox; TestFlight and App Store builds use APNs production. Never let a production ingress route select the sandbox/production host from request data.

Store app configuration as reviewed deployment configuration, for example:

```yaml
apps:
  deadwax:
    bundleId: app.deadwaxclub
    teamId: ABC123DEFG
    production:
      keyId: KEY1234567
      secretArn: arn:aws:secretsmanager:eu-west-1:...:secret:apns/prod/team-a
  diald:
    bundleId: app.dialdclub
    teamId: ABC123DEFG
    production:
      keyId: KEY1234567
      secretArn: arn:aws:secretsmanager:eu-west-1:...:secret:apns/prod/team-a
```

Apps on the same Apple team/environment may share a team-scoped key and pool; apps on different teams or environments must not.

## Alternative deployment patterns

### Fly.io plus Managed Postgres

A Dockerized API and worker can run as separate Fly process groups. A real Node/Go/Rust HTTP/2 client can maintain APNs connections. Fly can deploy Dockerfiles with rolling, canary, or blue-green replacement and supports runtime secrets. Managed Postgres includes high availability, failover, encrypted backups, and connection pooling. See [Deploy an app](https://fly.io/docs/launch/deploy/), [Fly secrets](https://fly.io/docs/apps/secrets/), and [Managed Postgres](https://fly.io/docs/mpg/).

The database must implement a durable outbox/queue with transactional claims, leases, retry scheduling, and dead-letter state, or the worker must consume a separate managed queue. This is viable at small scale, but the gateway team owns more queue correctness than with SQS. Fly notes that worker health is better monitored via queue-depth/dead-man metrics because workers may expose no routable HTTP service. See [Fly health checks](https://fly.io/docs/reference/health-checks/).

Deployment outline:

```sh
fly launch --no-deploy
fly secrets set APNS_PRODUCTION_KEY_P8=- < ./AuthKey_PRODUCTION.p8
fly deploy --strategy canary
fly checks list
fly status
```

Do not pass the key literal as a command-line argument, where shell history and process inspection can expose it.

### Cloudflare Workers and Queues

Cloudflare Queues provides at-least-once delivery, explicit retry/delay, DLQs, and pull consumers. Its docs recommend unique IDs and application-level deduplication. See [Queues delivery guarantees](https://developers.cloudflare.com/queues/reference/delivery-guarantees/), [batching and retries](https://developers.cloudflare.com/queues/configuration/batching-retries/), and [dead-letter queues](https://developers.cloudflare.com/queues/configuration/dead-letter-queues/).

However, Cloudflare lists `node:http2` as a non-functional stub. APNs requires HTTP/2 and expects connection/stream/GOAWAY management. Therefore do not select a Worker as the APNs sender without a proven, vendor-supported HTTP/2 mechanism. A Cloudflare API plus Queue can still feed a pull consumer on Fly, ECS, or another long-running host, but that adds a second infrastructure provider without removing the sender runtime. See [Cloudflare Node.js compatibility](https://developers.cloudflare.com/workers/runtime-apis/nodejs/) and [Queue pull consumers](https://developers.cloudflare.com/queues/configuration/pull-consumers/).

## Testing and acceptance matrix

### Gateway unit tests

- JWT signer: exact ES256 header/claims, Team ID/key ID, cached lifetime, one refresh during the 20–60 minute window, clock-skew boundaries, and no per-request minting.
- App config resolution: request app ID resolves the only allowed team/topic/environment/key; unrecognized combinations fail closed.
- Token encoding/validation: preserve leading zeroes, accept valid hex without fixed length assumptions, normalize only as specified by the API.
- Payload builder: required `aps`, push type/priority combinations, 4,096-byte boundary, category/thread/collapse mapping, 64-byte collapse limit, and rejection/redaction of disallowed fields.
- Idempotency: same `(app_id, event_id, payload_hash)` returns the original receipt; same key with a different payload is a conflict.
- Fan-out: zero, one, and many active installations; inactive installations excluded; cross-app and cross-principal leakage impossible.
- Response classifier: every documented APNs reason maps to accepted, retry, deactivate, or terminal failure; unknown reasons fail safely and visibly.
- `410` race: an older invalidation timestamp cannot disable a newer registration.
- Queue lease/retry: visibility extension, bounded attempts, expiration, DLQ transition, and crash recovery.
- Secrets/logging: snapshot tests prove logs contain hashes/IDs rather than raw tokens, credentials, or sensitive payloads.

### Protocol integration tests

Run workers against a controllable local TLS HTTP/2 fake APNs server. Assert:

- Concurrent streams receive independently correlated responses.
- `GOAWAY`, stream reset, idle timeout, connection refusal, TLS failure, and ambiguous disconnect produce the intended retry behavior.
- Mock `200`, permanent `400`, refreshed-token `403`, delayed `429`, invalidating `410`, and delayed/backoff `500/503` responses.
- A worker shutdown stops polling, finishes/drains streams, and leaves uncompleted jobs recoverable.
- Multiple team/environment pools cannot share sessions or secrets.

Local mocks are essential because Apple's public tools do not offer reliable production failure injection.

### Apple end-to-end acceptance

Apple's Push Notifications Console is the independent oracle. It can validate a provider JWT, validate a device token for a selected bundle ID, send a test payload, generate an equivalent cURL command, and expose development Delivery Logs for up to seven days using `apns-unique-id`. See [Testing with the Push Notifications Console](https://developer.apple.com/documentation/usernotifications/testing-notifications-using-the-push-notification-console).

For each application and environment:

1. Confirm the built app has the expected `aps-environment` entitlement and bundle ID.
2. On a physical device, grant permission, capture the registration callback, and verify the gateway registration row contains the correct app/environment without logging the raw token.
3. Validate the `.p8`/JWT in Apple's console.
4. Validate the captured device token against the selected bundle ID.
5. Send a direct console notification. This isolates app/signing/APNs configuration from the gateway.
6. Submit the same semantic notification through the gateway sandbox path and correlate gateway `event_id`, `apns-id`, and, where available, development `apns-unique-id`/Delivery Log.
7. Test foreground receipt, background receipt, terminated-app tap routing, multiple devices on one account, account switch on one device, denied notification permission, token re-registration, reinstall, and logout unlinking.
8. Test TestFlight against production APNs, then an App Store/release smoke test. Do not send a TestFlight token to sandbox.
9. Verify canonical inbox refresh after a deliberately collapsed, expired, or offline notification; push loss must not lose business state.

### Infrastructure acceptance and drills

- Load test event ingress, fan-out, and worker concurrency without using production user tokens.
- Prove API rate limits and per-app credential isolation.
- Stop one worker during active delivery; its messages must become available and complete on another worker.
- Break APNs egress; queue age should rise and alarm without dropping jobs.
- Insert poison jobs; they must reach the DLQ and alert after bounded retries.
- Rotate an APNs key by introducing the new secret/key configuration, opening new pools, validating sends, then revoking the old key and closing old pools.
- Add a new app topic and restart/recreate the affected team/environment pool before its first production send, as Apple's connection binding rules require.
- Restore DynamoDB/registry backup or a staging clone and verify no cross-environment tokens are sent.
- Exercise a rollback to the previous container image while leaving queue and registry schemas backward-compatible.

## Required metrics and alerts

At minimum emit per app and environment:

- ingress accepted/rejected/idempotent-conflict counts;
- queue depth, age of oldest job, receive count, and DLQ depth;
- event-to-APNs-accept latency;
- APNs result count by status and reason, without raw token labels;
- active/inactive installation counts and 410 invalidation rate;
- JWT age, refresh count, signing failures, pool reconnect/GOAWAY counts, and open streams;
- worker desired/running count, restarts, CPU, memory, and graceful-shutdown duration.

Page on oldest-job age, DLQ nonempty, widespread 403/config errors, loss of all workers, or a sharp cross-app increase in permanent token errors. A `200` acceptance metric is not a delivery metric.

## Facts agents must not accidentally change into stronger claims

- Direct APNs does not use CloudKit/iCloud identity, but Apple does not publish a sentence promising APNs for every device state or account configuration.
- APNs `200` means accepted, not displayed.
- `apns-id` is correlation, not documented deduplication.
- `apns-collapse-id` merges replaceable notifications; `aps.thread-id` groups notifications in the UI.
- SQS and Cloudflare Queues are at-least-once; consumers must be idempotent and a duplicate visible push remains theoretically possible after an ambiguous failure.
- Apple's current retry guidance says 5xx can be retried after 15 minutes with backoff; it does not document `Retry-After` for APNs.
- DynamoDB TTL cleanup is asynchronous, so expired items can remain visible for days and must be filtered by application logic.
- A shared gateway is multi-application, not necessarily multi-Apple-team on one connection. Separate connection pools are mandatory across teams and environments.

## Primary sources

### Apple

- [Registering your app with APNs](https://developer.apple.com/documentation/usernotifications/registering-your-app-with-apns)
- [Asking permission to use notifications](https://developer.apple.com/documentation/usernotifications/asking-permission-to-use-notifications)
- [`aps-environment` entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/aps-environment)
- [Setting up a remote notification server](https://developer.apple.com/documentation/usernotifications/setting-up-a-remote-notification-server)
- [Establishing a token-based connection](https://developer.apple.com/documentation/usernotifications/establishing-a-token-based-connection-to-apns)
- [Establishing a connection to APNs](https://developer.apple.com/documentation/usernotifications/establishing-a-connection-to-apns)
- [Sending notification requests to APNs](https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns)
- [Handling notification responses from APNs](https://developer.apple.com/documentation/usernotifications/handling-notification-responses-from-apns)
- [Generating a remote notification](https://developer.apple.com/documentation/usernotifications/generating-a-remote-notification)
- [Testing notifications using the Push Notifications Console](https://developer.apple.com/documentation/usernotifications/testing-notifications-using-the-push-notification-console)
- [Viewing push status using Metrics and APNs](https://developer.apple.com/documentation/usernotifications/viewing-the-status-of-push-notifications-using-metrics-and-apns)

### AWS

- [SQS at-least-once delivery](https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/standard-queues-at-least-once-delivery.html)
- [SQS visibility timeout and DLQs](https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-visibility-timeout.html)
- [DynamoDB conditional `PutItem`](https://docs.aws.amazon.com/amazondynamodb/latest/APIReference/API_PutItem.html)
- [DynamoDB TTL](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/TTL.html)
- [ECS Secrets Manager integration](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/specifying-sensitive-data-tutorial.html)
- [ECS scaling from SQS backlog](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/service-autoscaling-queue.html)
- [API Gateway JWT authorizers](https://docs.aws.amazon.com/apigateway/latest/developerguide/http-api-jwt-authorizer.html)

### Cloudflare and Fly.io

- [Cloudflare Queue delivery guarantees](https://developers.cloudflare.com/queues/reference/delivery-guarantees/)
- [Cloudflare Queue retries](https://developers.cloudflare.com/queues/configuration/batching-retries/)
- [Cloudflare Queue pull consumers](https://developers.cloudflare.com/queues/configuration/pull-consumers/)
- [Cloudflare Node.js compatibility](https://developers.cloudflare.com/workers/runtime-apis/nodejs/)
- [Fly deployment strategies](https://fly.io/docs/launch/deploy/)
- [Fly Managed Postgres](https://fly.io/docs/mpg/)
- [Fly secrets](https://fly.io/docs/apps/secrets/)
- [Fly health checks](https://fly.io/docs/reference/health-checks/)
