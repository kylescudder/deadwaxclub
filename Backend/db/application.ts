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
  const legacy = new URL("../../supabase/migrations/", import.meta.url);
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
  await upgradeLegacyPrivileges(client);
  await client.query(`create or replace function auth.role() returns text language sql stable as $$
    select case current_setting('role',true)
      when 'deadwax_api' then 'authenticated'
      when 'deadwax_anon' then 'anon'
      when 'deadwax_service' then 'service_role'
      else coalesce(nullif(current_setting('role',true),'none'),'anon') end
  $$`);
}
