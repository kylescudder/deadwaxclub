import { afterAll, beforeAll, expect, test } from 'bun:test'
import { readFile } from 'node:fs/promises'
import { Pool } from 'pg'

const databaseURL = process.env.TEST_DATABASE_URL
if (!databaseURL || new URL(databaseURL).pathname !== '/deadwax_test') {
  throw new Error('Set TEST_DATABASE_URL to a disposable deadwax_test database')
}
const pool = new Pool({ connectionString: databaseURL, max: 1 })
const users = [crypto.randomUUID(), crypto.randomUUID()]

async function refreshLease() {
  await pool.query(
    "insert into recovery_lease values(1,clock_timestamp(),clock_timestamp(),'quota-fixture') on conflict(id) do update set snapshot_started_at=clock_timestamp(),verified_at=clock_timestamp()"
  )
}

beforeAll(async () => {
  await refreshLease()
  // Verified identities create profiles and personal Collections through the
  // same triggers as sign-up.
  for (const id of users) {
    await pool.query(
      'insert into public.auth_user (id, name, email, email_verified) values ($1, $2, $3, true)',
      [id, 'Quota Check', `quota-${id}@example.test`]
    )
  }
})

afterAll(async () => {
  await pool.end()
})

test('a signed-in user can create a record and the lifetime ledger is written', async () => {
  await refreshLease()
  const client = await pool.connect()
  try {
    await client.query('begin')
    const album = crypto.randomUUID()
    const pressing = crypto.randomUUID()
    const record = crypto.randomUUID()
    await client.query("insert into public.albums (id, dedupe_key, title, artist) values ($1, $2, 'Q', 'D')", [album, 'quota-api:' + album])
    await client.query('insert into public.record_pressings (id, album_id, dedupe_key) values ($1, $2, $3)', [pressing, album, 'quota-api:' + pressing])
    const collection = (await client.query('select primary_collection_id from public.profiles where id = $1', [users[0]])).rows[0].primary_collection_id
    await client.query('set local role deadwax_api')
    await client.query("select set_config('deadwax.user_id', $1, true)", [users[0]])
    await client.query("insert into public.records (id, record_pressing_id, collection_id, status) values ($1, $2, $3, 'owned')", [record, pressing, collection])
    await client.query('reset role')
    const ledger = await client.query('select user_id from public.record_creation_events where record_id = $1', [record])
    expect(ledger.rows).toEqual([{ user_id: users[0] }])
    await client.query('set local role deadwax_api')
    // The ledger stays hidden from request roles.
    await expect(client.query('select * from public.record_creation_events')).rejects.toMatchObject({ code: '42501' })
  } finally {
    await client.query('rollback')
    client.release()
  }
})

test('authoritative record creation quota and entitlement checks pass', async () => {
  await refreshLease()
  const checks = await readFile(new URL('./record-creation-quota-checks.sql', import.meta.url), 'utf8')
  await pool.query(checks)
})
