import { mkdtemp, writeFile, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { beforeAll, afterAll, expect, test } from 'bun:test'
import { Pool } from 'pg'
import { validateRecoveryProof } from '../scripts/recovery-proof'
import { deploymentConfig } from '../scripts/config'
import { provisionRoles, provisionSync } from '../scripts/provision'
const now = Date.parse('2026-11-20T12:00:00Z')
const proof = {
  snapshotStartedAt: '2026-11-20T11:59:00Z',
  verifiedAt: '2026-11-20T11:59:30Z',
  snapshotID: 'test-object',
  nasVerified: true as const
}

test('recovery proof rejects unverified, stale, future and malformed evidence', () => {
  expect(validateRecoveryProof(proof, now)).toEqual(proof)
  for (const invalid of [
    null,
    {},
    { ...proof, nasVerified: false },
    { ...proof, snapshotID: '' },
    { ...proof, snapshotStartedAt: '2026-11-20T11:50:00Z' },
    { ...proof, snapshotStartedAt: '2026-11-20T12:01:00Z' },
    { ...proof, verifiedAt: '2026-11-20T11:58:00Z' },
    { ...proof, verifiedAt: '2026-11-20T12:01:00Z' },
    { ...proof, extra: true }
  ]) {
    expect(() => validateRecoveryProof(invalid, now)).toThrow()
  }
})

const connection = process.env.INFRA_TEST_DATABASE_URL
if (connection && !new URL(connection).pathname.endsWith('_infra_test'))
  throw new Error(
    'INFRA_TEST_DATABASE_URL must point to a disposable _infra_test database'
  )
const integration = connection ? test : test.skip
const pool = connection
  ? new Pool({ connectionString: connection, max: 2 })
  : undefined
const config = await deploymentConfig()
beforeAll(async () => {
  if (!pool) return
  await pool.query(
    "insert into recovery_lease values(1,clock_timestamp(),clock_timestamp(),'infra-fixture') on conflict(id) do update set snapshot_started_at=clock_timestamp(),verified_at=clock_timestamp()"
  )
})
afterAll(async () => {
  await pool?.end()
})

integration(
  'runtime cannot publish recovery evidence and stale proof fences writes',
  async () => {
    const client = await pool!.connect()
    try {
      await client.query('begin')
      await client.query(`set local role "${config.runtimeRole}"`)
      try {
        await client.query("update recovery_lease set snapshot_id='forged'")
        throw new Error('Runtime forged recovery proof')
      } catch (error) {
        expect((error as { code?: string }).code).toBe('42501')
      }
      await client.query('rollback')
      await pool!.query(
        "update recovery_lease set snapshot_started_at=clock_timestamp()-interval '601 seconds'"
      )
      await client.query('begin')
      await client.query(
        `set local role "${config.serviceRole ? config.runtimeRole : config.apiRole}"`
      )
      try {
        await client.query(
          "insert into auth_rate_limit(id,key,count,last_request) values('infra-fenced','infra-fenced',1,0)"
        )
        throw new Error('Unrecoverable write accepted')
      } catch (error) {
        expect((error as { code?: string }).code).toBe('DX006')
      }
      await client.query('rollback')
    } finally {
      await client.query('rollback')
      client.release()
      await pool!.query(
        'update recovery_lease set snapshot_started_at=clock_timestamp(),verified_at=clock_timestamp()'
      )
    }
  }
)

integration(
  'DBA role provisioning is repeatable and keeps app roles unprivileged',
  async () => {
    const client = await pool!.connect()
    try {
      await provisionRoles(client, config)
      await provisionRoles(client, config)
      const roles = await client.query(
        'select rolsuper,rolcreatedb,rolcreaterole,rolreplication,rolbypassrls from pg_roles where rolname=$1',
        [config.runtimeRole]
      )
      expect(Object.values(roles.rows[0]).some(Boolean)).toBe(false)
      // Better Auth runs as the runtime login itself, so it needs schema USAGE
      // even though the platform only grants it to <db>_runtime.
      const usage = await client.query(
        "select has_schema_privilege($1, 'public', 'usage') as usage",
        [config.runtimeRole]
      )
      expect(usage.rows[0].usage).toBe(true)
      // CI mirrors Herman's platform defaults; provisioning must strip them.
      const defaults = await client.query(
        'select 1 from pg_default_acl d, aclexplode(d.defaclacl) a where a.grantee=(select oid from pg_roles where rolname=$1)',
        [config.runtimeRole]
      )
      expect(defaults.rowCount).toBe(0)
    } finally {
      client.release()
    }
  }
)

integration(
  'replication provisioning uses only the app publication and never changes WAL settings',
  async () => {
    const client = await pool!.connect()
    try {
      const wal = (
        await client.query("select current_setting('wal_level') as value")
      ).rows[0].value
      const database = (await client.query('select current_database() as name'))
        .rows[0].name as string
      if (wal === 'logical') {
        await provisionSync(client, { ...config, database })
        await client.query(`grant select on auth_user to "${config.syncRole}"`)
        await provisionSync(client, { ...config, database })
        expect(
          (
            await client.query(
              "select has_table_privilege($1,'public.auth_user','SELECT') as allowed",
              [config.syncRole]
            )
          ).rows[0].allowed
        ).toBe(false)
        const tables = (
          await client.query(
            "select tablename from pg_publication_tables where pubname='powersync' order by tablename"
          )
        ).rows.map((row) => row.tablename)
        expect(tables).toEqual([...config.syncTables].sort())
        expect(tables.some((table) => table.startsWith('auth_'))).toBe(false)
      } else {
        await expect(
          provisionSync(client, { ...config, database })
        ).rejects.toThrow('Coordinate logical WAL')
      }
      expect(
        (await client.query("select current_setting('wal_level') as value"))
          .rows[0].value
      ).toBe(wal)
    } finally {
      client.release()
    }
  }
)

integration(
  'deferred commit rechecks recovery evidence after a concurrent expiry',
  async () => {
    const client = await pool!.connect()
    const key = 'infra-commit-' + crypto.randomUUID()
    try {
      await pool!.query(
        'update recovery_lease set snapshot_started_at=clock_timestamp(),verified_at=clock_timestamp()'
      )
      await client.query('begin')
      await client.query(
        `set local role "${config.serviceRole ? config.runtimeRole : config.apiRole}"`
      )
      await client.query(
        'insert into auth_rate_limit(id,key,count,last_request) values($1,$1,1,0)',
        [key]
      )
      await pool!.query(
        "update recovery_lease set snapshot_started_at=clock_timestamp()-interval '601 seconds'"
      )
      let refused = false
      try {
        await client.query('commit')
      } catch (error) {
        refused = (error as { code: string }).code === 'DX006'
      }
      expect(refused).toBe(true)
      expect(
        (await pool!.query('select 1 from auth_rate_limit where id=$1', [key]))
          .rowCount
      ).toBe(0)
    } finally {
      await client.query('rollback')
      client.release()
      await pool!.query(
        'update recovery_lease set snapshot_started_at=clock_timestamp(),verified_at=clock_timestamp()'
      )
    }
  }
)

integration(
  'backup publisher uses the writer role and cannot replace newer evidence with an older snapshot',
  async () => {
    const folder = await mkdtemp(join(tmpdir(), 'backend-proof-'))
    const file = join(folder, 'proof.json')
    const url = new URL(connection!)
    url.searchParams.set('options', '-c role=' + config.recoveryRole)
    await pool!.query(
      "update recovery_lease set snapshot_started_at=clock_timestamp()-interval '10 seconds',verified_at=clock_timestamp()-interval '10 seconds'"
    )
    const at = Date.now()
    const newer = {
      snapshotStartedAt: new Date(at).toISOString(),
      verifiedAt: new Date(at).toISOString(),
      snapshotID: 'newer-infra-fixture',
      nasVerified: true
    }
    try {
      for (const evidence of [
        newer,
        {
          ...newer,
          snapshotStartedAt: new Date(at - 5000).toISOString(),
          snapshotID: 'older-infra-fixture'
        }
      ]) {
        await writeFile(file, JSON.stringify(evidence), { mode: 0o600 })
        const child = Bun.spawn(
          [process.execPath, 'scripts/publish-recovery-lease.ts', file],
          {
            env: { ...process.env, RECOVERY_DATABASE_URL: url.href },
            stdout: 'pipe',
            stderr: 'pipe'
          }
        )
        expect(await child.exited).toBe(0)
      }
      expect(
        (await pool!.query('select snapshot_id from recovery_lease where id=1'))
          .rows[0].snapshot_id
      ).toBe('newer-infra-fixture')
    } finally {
      await rm(folder, { recursive: true, force: true })
    }
  }
)
