import { readdir, readFile } from "node:fs/promises";
import type { PoolClient } from "pg";
import { scopeLegacySQL, upgradeLegacyPrivileges } from "./scope-legacy-roles";

export async function migrateApplication(client: PoolClient) {
  // Preserve the deployed ledger and every historical filename. New installs
  // map role identifiers to app scopes without altering the legacy source files.
  await client.query(
    "select pg_advisory_xact_lock(hashtext('deadwax_schema'))",
  );
  await client.query(
    "create schema if not exists deadwax_migrations; create table if not exists deadwax_migrations.applied(name text primary key)",
  );
  // Historical Supabase migrations, replayed under their original ledger names.
  const legacy = new URL("./legacy/", import.meta.url);
  const files = [
    ["identity.sql", new URL("./identity.sql", import.meta.url)],
    ...(await readdir(legacy))
      .filter(
        (name) => name.endsWith(".sql") && name !== "0002_storage_covers.sql",
      )
      .sort()
      .map((name) => [name, new URL(name, legacy)]),
    ...["access.sql", "recovery.sql", "device-unregister.sql"].map((name) => [
      name,
      new URL("./" + name, import.meta.url),
    ]),
  ] as [string, URL][];
  // The legacy Supabase SQL relies on PostgreSQL's default PUBLIC EXECUTE on new
  // functions (auth.uid(), RLS helpers), as on Deadwax's existing server. Herman's
  // platform provisioning revokes that default, so restore it only while legacy
  // files replay. Their explicit revokes still apply, and later functions keep the
  // platform default.
  const platformRevokesExecute = (
    await client.query(
      "select 1 from pg_default_acl where defaclrole = current_user::text::regrole and defaclnamespace = 0 and defaclobjtype = 'f' and not exists (select 1 from aclexplode(defaclacl) a where a.grantee = 0 and a.privilege_type = 'EXECUTE')",
    )
  ).rowCount;
  if (platformRevokesExecute)
    await client.query(
      "alter default privileges grant execute on functions to public",
    );
  try {
    await replayLegacy(client, files);
  } finally {
    if (platformRevokesExecute)
      await client.query(
        "alter default privileges revoke execute on functions from public",
      );
  }
  await upgradeLegacyPrivileges(client);
  // Supabase ran security-definer functions as a superuser, which bypasses the
  // record ledger's FORCE ROW LEVEL SECURITY. On Herman they run as the app's
  // owner role, so only the table owner gets a policy; request roles stay denied.
  await client.query(`do $$ begin
    if not exists (select 1 from pg_policy where polrelid = 'public.record_creation_events'::regclass
                   and polname = 'record_creation_events_owner') then
      execute format('create policy record_creation_events_owner on public.record_creation_events for all to %I using (true) with check (true)',
        (select pg_get_userbyid(relowner) from pg_class where oid = 'public.record_creation_events'::regclass));
    end if;
  end $$`);
  await client.query(`create or replace function auth.role() returns text language sql stable as $$
    select case current_setting('role',true)
      when 'deadwax_api' then 'authenticated'
      when 'deadwax_anon' then 'anon'
      when 'deadwax_service' then 'service_role'
      else coalesce(nullif(current_setting('role',true),'none'),'anon') end
  $$`);
}

async function replayLegacy(client: PoolClient, files: [string, URL][]) {
  for (const [name, file] of files) {
    const marker = await client.query(
      "insert into deadwax_migrations.applied(name) values($1) on conflict do nothing",
      [name],
    );
    if (marker.rowCount) {
      const sql = await readFile(file, "utf8");
      // Cluster memberships are DBA provisioning, never an owner migration.
      await client.query(
        scopeLegacySQL(
          sql.replace(/^grant service_role, anon to deadwax_runtime;$/m, ""),
        ),
      );
    }
  }
}
