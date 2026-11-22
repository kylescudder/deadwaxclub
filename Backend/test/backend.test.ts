import { afterAll, beforeEach, expect, test } from 'bun:test'
import { connectDatabase } from '../src/database'
import { createApplication } from '../src/application'
import { createAuth } from '../src/auth'

const databaseURL = process.env.DEADWAX_TEST_DATABASE_URL
if (!databaseURL || new URL(databaseURL).pathname !== '/deadwax_test') {
  throw new Error(
    'Set DEADWAX_TEST_DATABASE_URL to a disposable deadwax_test database'
  )
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
beforeEach(() => pool.query('truncate public.auth_rate_limit'))
afterAll(() => pool.end())

function call(path: string, options?: { body?: unknown; token?: string }) {
  const headers = new Headers()
  if (options?.body) headers.set('content-type', 'application/json')
  if (options?.token) headers.set('authorization', 'Bearer ' + options.token)
  return app(
    new Request(new URL(path, origin), {
      method: options?.body ? 'POST' : 'GET',
      headers,
      body: options?.body ? JSON.stringify(options.body) : undefined
    })
  )
}

test('verified identity retains its UUID in the profile and sync token, and stale backups fence writes', async () => {
  await pool.query('delete from public.recovery_lease')
  expect((await call('/health/live')).status).toBe(200)
  expect((await call('/health/ready')).status).toBe(503)
  await pool.query(
    "insert into public.recovery_lease values (1, now(), now(), 'disposable-test')"
  )
  expect((await call('/health/ready')).status).toBe(200)
  const email = crypto.randomUUID() + '@example.test'
  const credentials = { email, password: 'test-only-password' }
  const signup = await call('/api/auth/sign-up/email', {
    body: { ...credentials, name: 'Test Collector' }
  })
  expect(signup.status).toBe(200)
  const { user } = (await signup.json()) as { user: { id: string } }
  expect(
    (await pool.query('select id from profiles where id = $1', [user.id]))
      .rowCount
  ).toBe(0)
  expect(verifyLink).toBeString()
  const verification = await call(verifyLink!)
  expect(verification.status).toBeLessThan(400)
  const signIn = await call('/api/auth/sign-in/email', { body: credentials })
  expect(signIn.status).toBe(200)
  const { token } = (await signIn.json()) as { token: string }

  const profile = await call('/api/me', { token })
  expect(profile.status).toBe(200)
  expect(await profile.json()).toMatchObject({
    id: user.id,
    display_name: 'Test Collector'
  })

  const issued = await call('/api/auth/token', { token })
  expect(issued.status).toBe(200)
  const jwt = ((await issued.json()) as { token: string }).token
  const claims = JSON.parse(
    Buffer.from(jwt.split('.')[1]!, 'base64url').toString()
  )
  expect(claims).toMatchObject({ sub: user.id, aud: syncOrigin, iss: origin })

  const change = {
    id: user.id,
    table: 'profiles',
    op: 'patch',
    data: { display_name: 'Updated' }
  }
  expect((await call('/api/sync/upload', { body: change })).status).toBe(401)
  expect(
    (
      await call('/api/sync/upload', {
        body: { ...change, id: crypto.randomUUID() },
        token
      })
    ).status
  ).toBe(403)
  expect(
    (
      await call('/api/sync/upload', {
        body: { ...change, table: 'auth_account' },
        token
      })
    ).status
  ).toBe(422)
  expect((await call('/api/sync/upload', { body: change, token })).status).toBe(
    200
  )
  const collection = {
    id: crypto.randomUUID(),
    table: 'collections',
    op: 'put',
    data: { name: 'Queued collection', created_by: user.id }
  }
  expect(
    (await call('/api/sync/upload', { body: collection, token })).status
  ).toBe(200)
  expect(
    (await call('/api/sync/upload', { body: collection, token })).status
  ).toBe(200)
  const owners = await call('/api/library/get_collection_member_profiles', {
    body: { p_collection_id: collection.id },
    token
  })
  expect(owners.status).toBe(200)
  expect(await owners.json()).toEqual([
    expect.objectContaining({ id: user.id })
  ])
  const status = await call('/api/library/get_record_creation_status', {
    body: {},
    token
  })
  expect(await status.json()).toEqual([
    {
      free_limit: 5,
      has_verified_entitlement: false,
      lifetime_record_count: 0
    }
  ])
  expect(
    (
      await call('/api/iap/transactions', {
        body: { signedTransactionInfo: 'unverified' },
        token
      })
    ).status
  ).toBe(422)
  await pool.query(
    "update public.recovery_lease set snapshot_started_at = now() - interval '11 minutes'"
  )
  expect(
    (
      await call('/api/sync/upload', {
        body: { ...change, data: { display_name: 'Blocked' } },
        token
      })
    ).status
  ).toBe(503)
  expect(
    (
      await pool.query('select display_name from profiles where id = $1', [
        user.id
      ])
    ).rows[0]
  ).toEqual({ display_name: 'Updated' })
})

test('device unregister is authenticated, owner-scoped and idempotent', async () => {
  await pool.query(
    'update public.recovery_lease set snapshot_started_at=now(), verified_at=now()'
  )
  const accounts: { id: string; token: string }[] = []
  for (let i = 0; i < 2; i++) {
    const credentials = {
      email: crypto.randomUUID() + '@example.test',
      password: 'test-only-password'
    }
    const signup = await call('/api/auth/sign-up/email', {
      body: { ...credentials, name: 'Device test' }
    })
    expect(signup.status).toBe(200)
    const { user } = (await signup.json()) as { user: { id: string } }
    expect((await call(verifyLink!)).status).toBeLessThan(400)
    const signin = await call('/api/auth/sign-in/email', { body: credentials })
    const { token } = (await signin.json()) as { token: string }
    accounts.push({ id: user.id, token })
  }
  const apnsToken = crypto.randomUUID().replaceAll('-', '').repeat(2)
  for (const account of accounts) {
    expect(
      (
        await call('/api/devices', {
          token: account.token,
          body: {
            apns_token: apnsToken,
            device_name: 'Test device',
            environment: 'sandbox'
          }
        })
      ).status
    ).toBe(200)
  }
  const unregister = (token: string, deviceToken = apnsToken) =>
    app(
      new Request(new URL('/api/devices', origin), {
        method: 'DELETE',
        headers: {
          authorization: 'Bearer ' + token,
          'content-type': 'application/json'
        },
        body: JSON.stringify({ apns_token: deviceToken })
      })
    )
  expect((await unregister('')).status).toBe(401)
  expect((await unregister(accounts[0]!.token, 'invalid')).status).toBe(422)
  expect((await unregister(accounts[0]!.token)).status).toBe(200)
  expect((await unregister(accounts[0]!.token)).status).toBe(200)
  const remaining = await pool.query(
    'select user_id from public.device_tokens where apns_token=$1',
    [apnsToken]
  )
  expect(remaining.rows).toEqual([{ user_id: accounts[1]!.id }])
})

test('the website can read shared lists cross-origin without credentials', async () => {
  const preflight = await app(
    new Request(new URL('/api/public/get_shared_list', origin), {
      method: 'OPTIONS',
      headers: {
        origin: 'https://deadwaxclub.app',
        'access-control-request-method': 'POST',
        'access-control-request-headers': 'content-type'
      }
    })
  )
  expect(preflight.status).toBe(204)
  expect(preflight.headers.get('access-control-allow-origin')).toBe('*')
  expect(preflight.headers.get('access-control-allow-headers')).toBe(
    'content-type'
  )
  for (const path of [
    '/api/public/get_shared_list',
    '/api/public/get_shared_list_records'
  ]) {
    const missing = await call(path, { body: { token: 'zzzzzzzzzzzz' } })
    expect(missing.status).toBe(200)
    expect(await missing.json()).toEqual([])
    expect(missing.headers.get('access-control-allow-origin')).toBe('*')
  }
  const invalid = await call('/api/public/get_shared_list', {
    body: { token: 'not a token' }
  })
  expect(invalid.status).toBe(422)
  expect(invalid.headers.get('access-control-allow-origin')).toBe('*')
  // Authenticated endpoints stay same-origin only.
  expect(
    (await call('/api/me')).headers.get('access-control-allow-origin')
  ).toBeNull()
})
