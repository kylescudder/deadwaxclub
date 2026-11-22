# Backend deployment

The backend is a Bun API and PowerSync, running on Herman against the shared PostgreSQL server (`postgres:5432` on `platform-db`). There is no per-app PostgreSQL container. Application deployments never change shared server settings or restart the server.

`app.json` is the app-specific inventory: database, roles, recovery and sync tables, receiver URL and headers. Everything else in this directory is shared byte for byte between apps:
- the Compose files and the API Dockerfile;
- the PowerSync service configuration;
- the migration runner, recovery guard and proof publisher;
- the verification command;
- the release workflow.

App-specific pieces are the domain migrations (`db/` and `drizzle/`) and the PowerSync streams (`powersync/sync-config.yaml`).

## Releases

Merging to `main` with changes under `Backend/` runs `release-backend.yml`. It builds and attests a multi-platform API image and asks the app's deploy-core receiver (`deployURL` in `app.json`) to deploy that exact digest. The image is the whole backend release, because it carries `deploy/`. Herman's deploy-core hooks then:
1. verify the image's provenance;
2. take a local database dump;
3. require a fresh off-host recovery proof;
4. run owner migrations from the image;
5. install `compose.yaml`, `compose.shared.yaml`, `powersync/` and `app.json` from the image;
6. start `<project>-api` and `<project>-sync` (PowerSync is recreated whenever its configuration or pinned image changes);
7. accept the release with `bun deploy/verify.ts`.

A failed health check or acceptance restores the previous image together with its stack. Migrations are not reversed, so each one must stay compatible with the previous runtime.

`compose.yaml` names the services `<project>-api` and `<project>-sync`, because Compose publishes every service name as a DNS alias on every attached network. Each Compose project has:
- private sync networking;
- access to the shared `platform-db`;
- no host ports and no PostgreSQL service.

The PowerSync image is pinned by digest in `compose.shared.yaml`. Updating it is a normal Backend change.

## Host prerequisites (DBA, once per app)

1. **Database:** create it with Herman's platform tool, `scripts/provision-project.py <database>`. This creates `<database>_owner`/`<database>_runtime` with protected passwords and backup registration.
2. **PowerSync storage:** run `PROVISION_DATABASE_URL=<DBA URL ending /postgres> bun scripts/provision-postgres.ts databases`. This adds the PowerSync storage role and database.
3. **Roles:** run `PROVISION_DATABASE_URL=<DBA URL for the app database> bun scripts/provision-postgres.ts roles`.
   - It creates the app-scoped runtime, request and recovery roles and grants the runtime membership in its request roles.
   - It removes the platform's default table grants to the runtime login, so the runtime gets only what migrations grant.
   - It grants schema USAGE to the app roles.
   - Run it before the first migration.
   - The API connection URL sets `runtimeDefaultRole` from `app.json` as its role option.
4. **Migrations:** run `DATABASE_URL=<owner URL> bun scripts/migrate.ts` from an image. Releases do this automatically afterwards; migrations are idempotent.
5. **Sync role:** run `PROVISION_DATABASE_URL=<DBA URL for the app database> bun scripts/provision-postgres.ts sync`. This creates the replication role and grants it SELECT on the configured sync tables only. It refuses to run without logical WAL.
6. **Host files** in the deploy-core deployment directory:
   - `.env` from `compose.env.example`;
   - `secrets/api.env` and `secrets/powersync.env` (0600) from the examples;
   - a notification spool at `state/notifications`, mode 0700 for UID 1000.
   
   Releases install the rest.

Keep the public JWT audience and the internal JWKS URL aligned with the app. PowerSync and the API use separate credentials. Monitor connections, slot-retained WAL, storage and memory.

## Recovery

The deploy-core backup verifier runs every five minutes from launchd. It dumps the app and PowerSync storage databases, encrypts them to the NAS and checks the NAS copy. Only then does it write the four-field proof (`snapshotStartedAt`, `verifiedAt`, `snapshotID`, `nasVerified: true`) to `state/recovery-proof.json` and publish the lease with `scripts/publish-recovery-lease.ts`, using the dedicated recovery writer and never the runtime login.

The publisher rejects malformed, future, stale or unverified evidence. It never replaces a newer snapshot with an older one. The database guard fences writes when the proof is at least 600 seconds old or a transaction reaches 60 seconds, and API roles cannot update the lease.

Restore drills cover the app database, Better Auth/JWKS keys, notification spool, migration ledgers and PowerSync rebuild.
