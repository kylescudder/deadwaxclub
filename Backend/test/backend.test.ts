import { afterAll, expect, test } from 'bun:test'
import { connectDatabase } from '../src/database'
import { createApplication } from '../src/application'
import { createAuth } from '../src/auth'

const databaseURL = process.env.DEADWAX_TEST_DATABASE_URL
if (!databaseURL || new URL(databaseURL).pathname !== '/deadwax_test') {
  throw new Error('Set DEADWAX_TEST_DATABASE_URL to a disposable deadwax_test database')
}

const { db, pool } = connectDatabase(databaseURL)
const origin = 'http://localhost:3147'
const syncOrigin = 'https://sync.example.test'
let verifyLink: string | undefined
const auth = createAuth(db, {
  baseURL: origin,
  powerSyncURL: syncOrigin,
  secret: 'deadwax-disposable-test-secret-only',
  sendEmail: async (_, kind, url) => {
    if (kind === 'verify') verifyLink = url
  }
})
const app = createApplication(auth, pool, origin)
afterAll(() => pool.end())

function call(path: string, options?: { body?: unknown; token?: string }) {
  const headers = new Headers()
  if (options?.body) headers.set('content-type', 'application/json')
  if (options?.token) headers.set('authorization', 'Bearer ' + options.token)
  return app(new Request(new URL(path, origin), {
    method: options?.body ? 'POST' : 'GET',
    headers,
    body: options?.body ? JSON.stringify(options.body) : undefined
  }))
}

test('verified identity retains its UUID in the profile and sync token, and stale backups fence writes', async () => {
  await pool.query('delete from public.recovery_lease')
  expect((await call('/health/live')).status).toBe(200)
  expect((await call('/health/ready')).status).toBe(503)
  await pool.query("insert into public.recovery_lease values (1, now(), now(), 'disposable-test')")
  expect((await call('/health/ready')).status).toBe(200)
  const email = crypto.randomUUID() + '@example.test'
  const credentials = { email, password: 'test-only-password' }
  const signup = await call('/api/auth/sign-up/email', {
    body: { ...credentials, name: 'Test Collector' }
  })
  expect(signup.status).toBe(200)
  const { user } = await signup.json() as { user: { id: string } }
  expect((await pool.query('select id from profiles where id = $1', [user.id])).rowCount).toBe(0)
  expect(verifyLink).toBeString()
  const verification = await call(verifyLink!)
  expect(verification.status).toBeLessThan(400)
  const signIn = await call('/api/auth/sign-in/email', { body: credentials })
  expect(signIn.status).toBe(200)
  const { token } = await signIn.json() as { token: string }

  const profile = await call('/api/me', { token })
  expect(profile.status).toBe(200)
  expect(await profile.json()).toMatchObject({ id: user.id, display_name: 'Test Collector' })

  const issued = await call('/api/auth/token', { token })
  expect(issued.status).toBe(200)
  const jwt = (await issued.json() as { token: string }).token
  const claims = JSON.parse(Buffer.from(jwt.split('.')[1]!, 'base64url').toString())
  expect(claims).toMatchObject({ sub: user.id, aud: syncOrigin, iss: origin })

  const change = { id: user.id, table: 'profiles', op: 'patch', data: { display_name: 'Updated' } }
  expect((await call('/api/sync/upload', { body: change })).status).toBe(401)
  expect((await call('/api/sync/upload', { body: { ...change, id: crypto.randomUUID() }, token })).status).toBe(403)
  expect((await call('/api/sync/upload', { body: { ...change, table: 'auth_account' }, token })).status).toBe(422)
  expect((await call('/api/sync/upload', { body: change, token })).status).toBe(200)
  const collection = {
    id: crypto.randomUUID(), table: 'collections', op: 'put',
    data: { name: 'Queued collection', created_by: user.id }
  }
  expect((await call('/api/sync/upload', { body: collection, token })).status).toBe(200)
  expect((await call('/api/sync/upload', { body: collection, token })).status).toBe(200)
  const owners = await call('/api/library/get_collection_member_profiles', {
    body: { p_collection_id: collection.id }, token
  })
  expect(owners.status).toBe(200)
  expect(await owners.json()).toEqual([expect.objectContaining({ id: user.id })])
  const status = await call('/api/library/get_record_creation_status', { body: {}, token })
  expect(await status.json()).toEqual([{
    free_limit: 5, has_verified_entitlement: false, lifetime_record_count: 0
  }])
  expect((await call('/api/iap/transactions', {
    body: { signedTransactionInfo: 'unverified' }, token
  })).status).toBe(422)
  await pool.query("update public.recovery_lease set snapshot_started_at = now() - interval '11 minutes'")
  expect((await call('/api/sync/upload', { body: { ...change, data: { display_name: 'Blocked' } }, token })).status).toBe(503)
  expect((await pool.query('select display_name from profiles where id = $1', [user.id])).rows[0]).toEqual({ display_name: 'Updated' })
})
