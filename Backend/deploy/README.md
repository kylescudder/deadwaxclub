# Shared Herman backend infrastructure

Both apps use Herman's existing PostgreSQL server on `platform-db`, at `postgres:5432`. Do not create a separate PostgreSQL container or cluster, change shared server settings, or restart it from an application deployment.

`app.json` is the app-specific database/role/table inventory. The Compose file, API Dockerfile, PowerSync service configuration, migration runner, recovery guards/publisher, verification command and backend release workflow are shared byte for byte. Domain migration histories and PowerSync queries remain app-specific.

## Provisioning order (DBA, before deployment)

1. Read the installed platform runbook and audit current capacity, owners, logical WAL, replication slots, role memberships and backups. Passwords remain in protected host files. No secrets are generated, printed or committed by these scripts.
2. If the application and PowerSync storage databases do not exist, run `PROVISION_DATABASE_URL=<DBA maintenance URL ending /postgres> bun scripts/provision-postgres.ts databases`. Existing databases with unexpected ownership cause a refusal rather than an ownership change. Both databases are created on the same server as the other Herman databases.
3. Connect to the app database with its DBA credential: `PROVISION_DATABASE_URL=... bun scripts/provision-postgres.ts roles`. This creates only app-scoped roles and grants the runtime membership in its own request roles. The recovery writer is separate; use a dedicated login with membership in the configured recovery role, never the API login. Set the API connection URL role option to `runtimeDefaultRole` in `app.json` (the example URL shows the encoding); do not enable INHERIT on Deadwax runtime. Set login passwords using the host's existing secure provisioning process, and audit other-database CONNECT/ACL access.
4. Run `DATABASE_URL=<protected application owner URL> bun scripts/migrate.ts` from the candidate image. Keep existing Drizzle and domain SQL journals. Do not use runtime credentials for migrations. Re-running migrations is idempotent.
5. With logical WAL already configured by the platform operator, run `PROVISION_DATABASE_URL=<DBA app URL> bun scripts/provision-postgres.ts sync`. It grants the dedicated replication role SELECT on the configured publication tables only. No auth tables are included. It refuses to change WAL settings. Use the separate storage login/database from `app.json`.

Deadwax's historical SQL is imported by an app adapter. Role identifiers are mapped to `deadwax_api`, `deadwax_anon` and `deadwax_service` without changing historical files or their ledger. Existing app-local ACLs/policies are transferred to the scoped roles. Generic roles used by other databases are never created, renamed or altered. Provisioning removes only the old generic memberships from Deadwax's own runtime role. Run this on the app database, never on another project's database.

## Install and release

Build from repository root: `docker build -f Backend/Dockerfile --build-arg SOURCE_REVISION=<commit> .`. The shared image typechecks and bundles the API, installs frozen Bun dependencies and retains both migration adapters. It runs as UID 1000 with a liveness check.

Use a dedicated deploy-core application entry for each API, generic Compose service `api`, and image variable `BACKEND_IMAGE`. Copy the reviewed `app.json` to the deployment directory as protected `backend.json` for the central hooks. Install the matching Compose, registry entry and hooks together before enabling the new receiver contract. Copy `compose.env.example` to the protected deployment `.env`, set immutable image digests and the reviewed ingress network, and keep `api.env` / `powersync.env` mode 0600. Each Compose project has private sync networking and app-specific ingress aliases, shared `platform-db` access, no host ports and no PostgreSQL service. Create the notification spool mode 0700 for UID 1000 and back it up encrypted.

Install the app's `powersync/` directory as configuration; its streams remain app-specific. Keep the public JWT audience and internal JWKS URL aligned with that app. PowerSync and API require separate credentials. Monitor connections, slot-retained WAL, storage and memory; configured limits are not evidence of production capacity.

`release-backend.yml` builds and attests multi-platform images. Deployment requires `API_DEPLOY_ENABLED=true` and `API_DEPLOY_CONTRACT=shared-backend-v1`, set only after the matching Compose/registry/hooks are installed on Herman; before that images may be built/published but no webhook request is sent. It also requires the app's protected receiver URL/Access/HMAC settings provisioned. `deploy-core-candidate/` is reviewable input for a central immutable deploy-core release, not an instruction to edit an installed release. The common prepare hook dumps the correct shared-server app database, validates a fresh verified off-host proof from protected `state/recovery-proof.json`, and uses its protected owner password for migrations. The trusted NAS backup verifier must atomically maintain that per-app proof, and its snapshot must include the shared-server database, keys, configuration and spool. A local dump alone never satisfies this gate. The common acceptance command checks liveness, fresh recovery evidence and JWKS before host acceptance.

## Recovery and rollback

The backup verifier supplies a four-field JSON proof (`snapshotStartedAt`, `verifiedAt`, `snapshotID`, `nasVerified: true`) only after an encrypted off-host snapshot is verified. Run `RECOVERY_DATABASE_URL=<dedicated writer> bun scripts/publish-recovery-lease.ts <proof-file>` from the app image. Never use runtime credentials or publish proof merely because a deploy backup command returned.

The shared publisher rejects malformed/future/stale/unverified evidence and cannot replace a newer snapshot with an older one. The shared database guard fences authoritative writes before execution and at deferred commit if proof is at least 600 seconds old or a transaction reaches 60 seconds. API roles cannot update the lease. Do not fabricate proof or bypass fencing to activate an app.

Restore drills must include the app database, Better Auth/JWKS keys, spool, migration journals and PowerSync reconstruction. Restore keys independently of the host and verify cross-account isolation and first sync. Record measured RPO/RTO; local tests alone prove neither. Roll back the image through deploy-core; migrations are not reversed and must remain compatible with the previous runtime.

## Existing dedicated-cluster cutover

If an app already has data in a dedicated cluster, do not simply switch its URL. Fence writes, take and verify its encrypted off-host snapshot, restore into the scoped database on the shared server (preserving identities and migration journals), reconcile ownership/ACLs, run owner migrations, rebuild PowerSync storage/slots, and verify row counts, sign-in and first sync before routing traffic. Keep the previous cluster fenced and recoverable until the restore drill and cutover are accepted. Shared-server capacity and logical WAL must be checked first; this repository does not restart the shared server or automatically copy production data.

## Host status

The repository changes can be verified locally. SSH access to Herman was denied during this work; shared-server capacity, actual role/database inventory, receiver installation, backup verifier integration and live deployment remain unverified. No server changes or production cutover were performed.
