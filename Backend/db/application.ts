import { readdir, readFile } from 'node:fs/promises'
import type { PoolClient } from 'pg'

// Applies Backend/db/migrations/*.sql once each, in filename order, recording
// every applied file in deadwax_migrations.applied. Runs as the database owner
// inside the deployment migration transaction.
export async function migrateApplication(client: PoolClient) {
  await client.query("select pg_advisory_xact_lock(hashtext('deadwax_schema'))")
  await client.query(
    'create schema if not exists deadwax_migrations; create table if not exists deadwax_migrations.applied(name text primary key)'
  )
  const folder = new URL('./migrations/', import.meta.url)
  const files = (await readdir(folder))
    .filter((name) => /^\d{4}_[a-z0-9_]+\.sql$/.test(name))
    .sort()
  for (const name of files) {
    const marker = await client.query(
      'insert into deadwax_migrations.applied(name) values($1) on conflict do nothing',
      [name]
    )
    if (marker.rowCount)
      await client.query(await readFile(new URL(name, folder), 'utf8'))
  }
}
