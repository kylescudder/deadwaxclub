import { readFile } from 'node:fs/promises'
import type { Pool, PoolClient } from 'pg'
import { migrate } from 'drizzle-orm/node-postgres/migrator'
import type { Database } from '../src/database'
import { deploymentConfig, identifier } from './config'

export async function migrateDeployment(
  db: Database,
  pool: Pool,
  migrateApplication: (client: PoolClient) => Promise<void>
) {
  const config = await deploymentConfig()
  // Drizzle's existing journal is retained. Application SQL history is never rewritten.
  await migrate(db, {
    migrationsFolder: new URL('../drizzle', import.meta.url).pathname
  })
  const client = await pool.connect()
  try {
    await client.query('begin')
    await client.query(
      "select pg_advisory_xact_lock(hashtext('backend-infrastructure-migrations'))"
    )
    await migrateApplication(client)
    await client.query(
      await readFile(
        new URL('../deploy/recovery-guard.sql', import.meta.url),
        'utf8'
      )
    )
    for (const table of config.recoveryTables) {
      const target = 'public.' + identifier(table)
      await client.query(`drop trigger if exists recovery_before on ${target}`)
      await client.query(`drop trigger if exists recovery_commit on ${target}`)
      await client.query(
        `create trigger recovery_before before insert or update or delete on ${target} for each statement execute function public.guard_recoverable_mutation()`
      )
      await client.query(
        `create constraint trigger recovery_commit after insert or update or delete on ${target} deferrable initially deferred for each row execute function public.guard_recoverable_mutation()`
      )
    }
    const runtimeRoles = [
      config.apiRole,
      config.runtimeRole,
      config.anonymousRole,
      config.serviceRole
    ]
      .filter(Boolean)
      .map((role) => identifier(role!))
      .join(', ')
    await client.query(
      `revoke all on public.recovery_lease from public, ${runtimeRoles}`
    )
    await client.query(
      `grant execute on function public.require_recovery_lease() to ${runtimeRoles}`
    )
    await client.query(
      `grant select, insert, update on public.recovery_lease to ${identifier(config.recoveryRole)}`
    )
    await client.query('commit')
  } catch (error) {
    await client.query('rollback')
    throw error
  } finally {
    client.release()
  }
}
