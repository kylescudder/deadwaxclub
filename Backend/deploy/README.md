# Deadwax API and PowerSync on Herman

The app connects to the Better Auth API and a separate PowerSync origin. This
deployment uses the Deadwax SQL migrations for collection and list access
policies, normalized records, the lifetime quota ledger, and Apple entitlement
contracts. The migrations run on PostgreSQL. The `auth.users` projection
maintains the UUIDs used by existing foreign keys and row policies.

## Isolated device test

Use a dedicated PostgreSQL cluster with logical replication enabled and a
separate PowerSync storage database. The role bootstrap creates cluster-wide
names used by the original SQL grants, so run it once in the dedicated cluster.

1. Run `db/roles.sql` as the cluster bootstrap role. Run `bun db/migrate.ts`
   from the API image using the Deadwax database owner.
2. Give the API login membership in `deadwax_runtime` and set its database
   connection option to `-c role=deadwax_runtime`. The runtime has no schema
   ownership. Grant the PowerSync replication login read access only to the
   tables in the `powersync` publication. Use a separate role to publish
   verified backup evidence to `public.recovery_lease`.
3. Install the compose candidate through the host's image deploy process.
   Place the checked-in `supabase/powersync/sync_rules.yaml` next to
   `powersync.yaml` in the host configuration. Provision the image digests,
   private network names, and read-only env files. Create the writable
   notification spool for container UID 1000 and include it in backups.
4. Configure the API with `DATABASE_URL`, `BETTER_AUTH_URL`,
   `BETTER_AUTH_SECRET`, `POWERSYNC_URL`, `BREVO_API_KEY`,
   `AUTH_EMAIL_FROM`, `APPLE_CLIENT_ID`, `APPLE_CLIENT_SECRET`,
   `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`,
   `APPLE_ROOT_CERTIFICATES_BASE64`, and `APPLE_APPLE_ID`.
   Configure PowerSync's database URIs, internal JWKS URL
   (`/api/auth/jwks`), public audience, and admin key as shown in
   `powersync.yaml`.
5. Have the backup verifier publish proof from a verified snapshot using
   `bun db/publish-recovery-lease.ts /path/to/proof.json` with the dedicated
   `RECOVERY_DATABASE_URL`. The proof contains `snapshotStartedAt`,
   `verifiedAt`, `snapshotID`, and `nasVerified`. The API fails its readiness
   check until the proof is fresh. Validate restore as well as freshness.
6. Verify the API's public `/health/ready` and PowerSync's public
   `/probes/readiness`. Use a disposable account to check sign-in, a signed
   sandbox StoreKit transaction, and a first sync with replayed data. Set
   `API_BASE_URL` and `POWERSYNC_BASE_URL` in GitHub to these verified public
   origins before dispatching the signed TestFlight workflow.

Use a fresh test installation or a disposable same-UUID upgrade fixture.
An upgraded production installation binds the legacy SQLite queue to its
original account and refuses to upload it through a different test account.
