import { migrate } from 'drizzle-orm/node-postgres/migrator'
import { readdir, readFile } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'
import { connectDatabase } from '../src/database'

const databaseURL = process.env.DATABASE_URL
if (!databaseURL) throw new Error('DATABASE_URL is required')

const { db, pool } = connectDatabase(databaseURL)
const migrationsFolder = fileURLToPath(new URL('../drizzle', import.meta.url))
const legacyDirectory = new URL('../../supabase/migrations/', import.meta.url)

try {
  await migrate(db, { migrationsFolder })
  const client = await pool.connect()
  try {
    await client.query('begin')
    await client.query("select pg_advisory_xact_lock(hashtext('deadwax_schema'))")
    await client.query(`
      create schema if not exists deadwax_migrations;
      create table if not exists deadwax_migrations.applied (
        name text primary key
      );
    `)
    const files = [
      ['identity.sql', new URL('./identity.sql', import.meta.url)],
      ...(await readdir(legacyDirectory))
        .filter((name) => name.endsWith('.sql') && name !== '0002_storage_covers.sql')
        .sort()
        .map((name) => [name, new URL(name, legacyDirectory)]),
      ['access.sql', new URL('./access.sql', import.meta.url)],
      ['recovery.sql', new URL('./recovery.sql', import.meta.url)],
      ['device-unregister.sql', new URL('./device-unregister.sql', import.meta.url)],
    ] as const

    for (const [name, file] of files) {
      const marker = await client.query(
        'insert into deadwax_migrations.applied (name) values ($1) on conflict do nothing',
        [name]
      )
      if (marker.rowCount) await client.query(await readFile(file, 'utf8'))
    }
    await client.query('commit')
  } catch (error) {
    await client.query('rollback')
    throw error
  } finally {
    client.release()
  }
} finally {
  await pool.end()
}
