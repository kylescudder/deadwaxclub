# Shared APNs gateway infrastructure runbook

This is the reference provisioning, deployment, secret-rotation, and recovery
runbook. It assumes a new `kylescudder/push-gateway` TypeScript repository and
AWS CDK v2. The gateway is shared infrastructure; it must not live inside any
one application's Supabase project.

## Reference topology

```text
                         +---------------- DynamoDB Installations
iOS -> API Gateway ------+ registration Lambda
       |                 +---------------- CloudWatch metrics/logs
       |
source -> event Lambda -> EventReceipts conditional write -> SQS PushJobs
                                                              |
                                                              v
                                                    ECS Fargate workers (2+)
                                                              |
                                      Secrets Manager/KMS ----+----> APNs HTTP/2
                                                              |
                                                       Deliveries table

SQS PushJobs -- bounded redrive --> SQS PushJobsDLQ --> alarm/operator replay
```

Use Lambda only for short validation, identity verification, conditional
writes, and enqueue. APNs delivery runs in long-lived Fargate tasks so the
process can reuse HTTP/2 connections, cache provider JWTs, drain streams, and
react correctly to `GOAWAY`.

Cloudflare Workers are not the reference sender: their documented
`node:http2` compatibility is a non-functional stub. Fly.io plus managed
Postgres is viable for a smaller operator footprint, but only if its worker
implements an equally durable leased queue. Do not deploy a direct APNs sender
on a runtime without vendor-supported outbound HTTP/2.

## Repository layout

Create this shape before application cutover:

```text
push-gateway/
  .github/workflows/ci.yml
  .github/workflows/deploy-staging.yml
  .github/workflows/deploy-production.yml
  bin/push-gateway.ts
  config/apps.staging.yml
  config/apps.production.yml
  infra/
    app.ts
    data-stack.ts
    queue-stack.ts
    ingress-stack.ts
    source-relay-stack.ts
    worker-stack.ts
    observability-stack.ts
  src/contracts/
    installation.ts
    push-event.ts
  src/adapters/identity/oidc-jwks.ts
  src/adapters/source/supabase-webhook.ts
  src/adapters/source/supabase-outbox-relay.ts
  src/api/registration-handler.ts
  src/api/event-handler.ts
  src/apns/client-pool.ts
  src/apns/provider-token.ts
  src/apns/response-policy.ts
  src/persistence/
  src/worker/main.ts
  test/protocol/fake-apns-server.ts
  Dockerfile
  package.json
  tsconfig.json
```

Keep contracts and application services independent of AWS SDK and Supabase
types. AWS and Supabase code belongs under adapters.

## Prerequisites and ownership

Before provisioning, record these owners in the gateway README:

- AWS production account and staging account/role;
- AWS region (use one region near the products' primary users; examples below
  use `eu-west-1`);
- DNS zone and names such as `push-staging.deadwaxclub.app` and
  `push.deadwaxclub.app`;
- Apple Developer team ID, APNs key ID, `.p8` owner, and rotation date;
- application ID, bundle ID, supported APNs environment, OIDC issuer,
  audience, and JWKS URL for each app;
- on-call destination for queue-age, DLQ, auth, and APNs credential alarms.

Supabase Auth projects must expose asymmetric signing keys and a JWKS endpoint.
Do not teach the gateway a Supabase service-role key and do not use the legacy
shared HS256 secret. Configure each issuer explicitly and verify signature,
`iss`, `aud`, `sub`, and time claims. If an issuer cannot provide compatible
asymmetric JWTs, migrate its signing key before enabling client registration.

## Reviewed application configuration

Application configuration is non-secret and versioned. A request path selects
one entry; no client or source can override the topic, Apple team, or key.

```yaml
# config/apps.production.yml
apps:
  deadwaxclub:
    bundleId: com.example.deadwaxclub
    appleTeamId: ABC123DEFG
    allowedEnvironments: [production]
    apnsKeySecretArn: arn:aws:secretsmanager:eu-west-1:123456789012:secret:apns/team-a
    identity:
      issuerId: deadwax-supabase
      issuer: https://PROJECT.supabase.co/auth/v1
      audience: authenticated
      jwksUrl: https://PROJECT.supabase.co/auth/v1/.well-known/jwks.json
    ingressSecretArn: arn:aws:secretsmanager:eu-west-1:123456789012:secret:ingress/deadwax
```

Staging uses separate endpoints, tables, queues, secrets, roles, and logs.
Debug builds use APNs sandbox in staging. TestFlight and App Store builds use
APNs production. Do not infer environment solely from a build name at the
gateway; validate it against the selected application's allowlist.

## CDK stacks

The CDK entry point takes an explicit stage and fails closed:

```ts
const stage = app.node.tryGetContext("stage");
if (stage !== "staging" && stage !== "production") {
  throw new Error("pass -c stage=staging|production");
}

const names = { prefix: `push-gateway-${stage}`, stage };
const data = new GatewayDataStack(app, `${names.prefix}-data`, { names });
const queue = new GatewayQueueStack(app, `${names.prefix}-queue`, { names });
const ingress = new GatewayIngressStack(app, `${names.prefix}-ingress`, {
  names, data, queue,
});
const sourceRelay = new GatewaySourceRelayStack(app, `${names.prefix}-source-relay`, {
  names, data, queue,
});
const worker = new GatewayWorkerStack(app, `${names.prefix}-worker`, {
  names, data, queue,
});
new GatewayObservabilityStack(app, `${names.prefix}-observability`, {
  names, data, queue, ingress, sourceRelay, worker,
});
```

### Data stack

Create `Installations`, `EventReceipts`, and `Deliveries` tables using the key
shape in `REFERENCE_IMPLEMENTATION.md`.

- on-demand capacity initially;
- point-in-time recovery on in production;
- deletion protection on in production;
- AWS-owned table encryption plus a customer-managed KMS key for token
  envelope encryption;
- `GSI1` on installation principal lookup;
- TTL attribute named `expires_at` on receipts and deliveries;
- no broad table scan permissions for application roles.

The registration Lambda can encrypt/write installations. The event Lambda can
query the principal GSI, conditionally write receipts/deliveries, and enqueue.
The worker can read/decrypt installations and update deliveries. No role gets
unnecessary table-wide delete permissions.

### Queue stack

```ts
const dlq = new sqs.Queue(this, "PushJobsDLQ", {
  queueName: `${prefix}-jobs-dlq`,
  retentionPeriod: Duration.days(14),
  encryption: sqs.QueueEncryption.KMS_MANAGED,
});

const jobs = new sqs.Queue(this, "PushJobs", {
  queueName: `${prefix}-jobs`,
  visibilityTimeout: Duration.minutes(5),
  retentionPeriod: Duration.days(4),
  encryption: sqs.QueueEncryption.KMS_MANAGED,
  deadLetterQueue: { queue: dlq, maxReceiveCount: 5 },
});
```

The worker extends visibility for an active batch. A retry scheduled for Apple
`500`/`503` is delayed at least 15 minutes and then backed off. Poison messages
reach the DLQ after bounded attempts. Standard SQS is at-least-once; every
consumer path must check the delivery record before sending.

### Ingress stack

Create an API Gateway HTTP API with:

```text
PUT    /v1/apps/{application_id}/installations/{installation_id}
DELETE /v1/apps/{application_id}/installations/{installation_id}/account-link
POST   /v1/apps/{application_id}/events
GET    /health
```

Registration routes verify the app user's OIDC JWT in the Lambda or a Lambda
authorizer. Cache JWKS only according to HTTP cache semantics and refetch after
an unknown key ID. The gateway derives `principal_id` as
`<issuer_id>#<subject>`.

The event route accepts either the canonical event body or, on a separately
configured adapter route, a Supabase Database Webhook envelope. Canonical
producers sign a timestamped HMAC canonical request or use IAM/SigV4. During
the Supabase transition, the webhook adapter may accept a per-app bearer secret
in a static header because Database Webhooks cannot generate the canonical
signature. Compare it in constant time, keep it per app and stage, rate-limit
the route, and immediately normalize the envelope into `PushEvent v1`.

Configure body-size limits, WAF/rate limits where appropriate, structured
access logs with Authorization removed, an ACM certificate, and a Route 53
alias. Health must prove process/config readiness but must not expose secrets or
depend on APNs accepting a notification.

### Temporary Supabase source-relay stack

The Database Webhook is a fast path, not the durability boundary. Add an
EventBridge-scheduled Lambda for each Supabase-backed producer. Every minute it
connects over TLS using a dedicated Postgres login that can only select/update
`push_outbox`, atomically leases a bounded batch, normalizes each row, submits
it through the same event application service, and records `accepted_at` only
after the DynamoDB receipt and SQS enqueue are durable.

Provision the database login outside migrations and store its connection URI
in Secrets Manager. It must not be `postgres`, `service_role`, or an app user's
credential. Grant only schema usage plus select/update on `push_outbox`; the
table trigger remains the only insert path.

The claim operation runs in one transaction:

```sql
with candidates as (
  select event_id
  from public.push_outbox
  where accepted_at is null
    and next_attempt_at <= now()
    and (lease_until is null or lease_until < now())
  order by created_at
  for update skip locked
  limit $1
)
update public.push_outbox o
set lease_until = now() + interval '5 minutes',
    attempt_count = o.attempt_count + 1
from candidates c
where o.event_id = c.event_id
returning o.*;
```

On `202` (including an idempotent replay), set `accepted_at = now()`, clear the
lease/error, and retain the row for audit. On retryable failure, set a bounded
jittered `next_attempt_at`, clear the lease, and store a short redacted error.
On an invalid permanent payload, set `dead_at` and alert. A crashed Lambda
leaves a lease that expires. Metrics cover oldest unaccepted row, attempts,
dead rows, claim failures, and source database connectivity.

This adapter is intentionally disposable. When Deadwax's originator leaves
Supabase, its new backend sends the same canonical event and the relay Lambda,
database credential, webhook adapter, and outbox table can be deleted without
editing the gateway core, worker, or iOS app.

### Worker stack

Build one immutable Docker image. Run at least two production tasks across
availability zones, with deployment settings `minimumHealthyPercent: 100` and
`maximumHealthyPercent: 200`.

The task role gets only:

- receive/delete/change-visibility on `PushJobs`;
- read/update needed delivery and installation items;
- decrypt token ciphertext with the gateway KMS key;
- read only referenced APNs secrets;
- publish gateway metrics and logs.

Allow outbound TLS to APNs. The worker maintains distinct pools for
`(apple_team_id, environment)`, caches provider JWTs for 20–50 minutes, and
never lets one reach Apple's one-hour limit. `SIGTERM` stops polling, extends
visibility for active jobs, waits for streams, closes sessions, then exits.

Autoscale on backlog per running task with a minimum of two production tasks.
Do not use raw queue depth as the target and do not scale production to zero.

### Observability stack

Create dashboards and alarms per app/environment for:

- API auth failures, validation failures, throttles, and 5xx;
- accepted, replayed, and idempotency-conflict events;
- queue depth, oldest-message age, receive count, and non-empty DLQ;
- event-to-APNs-accept latency;
- APNs status/reason counts, `410` invalidations, token refreshes, reconnects,
  and `GOAWAY`;
- desired/running workers, restarts, CPU, memory, and graceful-shutdown time.

Page on a non-empty DLQ, excessive oldest-message age, all workers unavailable,
or a widespread `403`/configuration failure. APNs `200` means accepted, not
displayed; label the metric accordingly.

## Initial provisioning

Use CI workload identity for routine deployments. A human with the bootstrap
role performs only the initial setup:

```sh
aws sts get-caller-identity
npm ci
npm test
npm run build
npx cdk bootstrap aws://STAGING_ACCOUNT/eu-west-1
npx cdk bootstrap aws://PRODUCTION_ACCOUNT/eu-west-1
npx cdk synth -c stage=staging
npx cdk diff -c stage=staging
npx cdk deploy --all -c stage=staging
```

Never pass `.p8` contents directly as a shell argument. Create a temporary
input file with restrictive permissions or use the AWS console, import the
secret, then remove the temporary file through the team's approved secret
handling process. Store JSON such as:

```json
{
  "team_id": "ABC123DEFG",
  "key_id": "KEY1234567",
  "private_key_p8": "-----BEGIN PRIVATE KEY-----\n...\n-----END PRIVATE KEY-----"
}
```

Create separate per-stage ingress credentials. Record only secret ARNs in app
configuration and Supabase webhook setup; never commit credential values.

## GitHub Actions deployment

CI runs on every PR:

```yaml
- run: npm ci
- run: npm run format:check
- run: npm run lint
- run: npm run typecheck
- run: npm test
- run: npm run test:protocol
- run: npx cdk synth -c stage=staging
```

The staging workflow assumes a staging deploy role through GitHub OIDC, builds
and pushes an image, captures its digest, runs `cdk diff`, deploys, and executes
contract/smoke tests. Production is environment-protected and promotes that
same tested image digest; it does not rebuild source:

```sh
npx cdk diff -c stage=production -c imageDigest="$IMAGE_DIGEST"
npx cdk deploy --all -c stage=production -c imageDigest="$IMAGE_DIGEST" \
  --require-approval never
```

Require a human approval on the GitHub `production` environment and retain the
CDK diff as an artifact. Database/table key changes require an explicit
backward-compatible migration plan and restore test before approval.

## Onboarding an application

Repeat in staging, then production:

1. Confirm its bundle ID, Apple team, APNs environment, auth issuer, audience,
   JWKS URL, and application ID.
2. Add reviewed non-secret configuration.
3. Import/reference the appropriate team APNs key. The same team key may serve
   multiple topics; different teams/environments use separate pools.
4. Create a per-app ingress credential and configure the source adapter.
5. Deploy configuration; wait for all worker tasks to be healthy so a new
   topic never first appears on an already-bound stale APNs connection.
6. Configure the iOS gateway URL/application ID outside source control.
7. Complete the physical-device acceptance matrix before any producer cutover.
8. Enable exactly one visible delivery path per principal.

For Supabase Database Webhooks, target the app-specific adapter URL, set the
per-app authorization header, select `INSERT` only on `push_outbox`, and use a
small timeout with retries. Do not send the service-role key. The gateway must
respond `202` only after the idempotency receipt is durable and the job is
enqueued.

## Routine deployment and rollback

Deployment order is always compatible consumers before producers:

1. deploy backward-compatible DynamoDB/IAM changes;
2. deploy new workers and wait for healthy capacity;
3. deploy ingress Lambdas/routes;
4. run health, contract, and synthetic sandbox event tests;
5. enable application source changes last.

Rollback does not delete queues or tables:

1. stop source cutover or restore the legacy notification webhook for the
   affected app only;
2. promote the last known-good Lambda bundle and worker image digest;
3. leave jobs queued unless the payload version is incompatible;
4. redrive the DLQ only after the defect is fixed and idempotency is verified;
5. if client registration is faulty, clear `PUSH_GATEWAY_URL` in the next app
   configuration/build so the rollout adapter returns to legacy registration.

Never roll back by flushing a queue or deleting registrations. Those actions
lose delivery/audit state and are not needed for code rollback.

## Secret and key rotation

Rotate an APNs key by overlap:

1. create/import the new key secret and deploy configuration accepting both;
2. force workers to establish new pools and mint JWTs with the new key;
3. send Apple-console and gateway canaries for every topic/environment;
4. observe successful APNs accepts and no elevated `403`;
5. revoke the old key at Apple, remove its ARN, and redeploy;
6. verify old pools close and alarms stay clear.

Rotate an ingress credential by accepting current and next credential hashes
for a short window, updating the producer/webhook, proving successful events,
then removing the old hash. Rotate OIDC keys at the issuer; the JWKS adapter
must handle a new `kid` without a gateway deployment.

## Disaster recovery and operator drills

Quarterly, in staging:

- stop a worker during an active batch and prove another task completes it;
- block APNs egress and prove queue age alarms without lost jobs;
- send poison work and prove bounded redrive plus DLQ alarm;
- replay a DLQ item after correction and prove one visible delivery;
- restore or clone DynamoDB data and prove expired items are filtered;
- rotate a key using the overlap sequence;
- roll back to the previous image while queued schema versions remain readable;
- verify no staging process can read production secrets or tokens.

The authoritative protocol and retry evidence is in
`docs/research/shared-apns-gateway.md`; update that research before changing a
protocol assumption in this runbook.
