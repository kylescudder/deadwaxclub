import { afterAll, beforeEach, expect, test } from 'bun:test'
import { connectDatabase } from '../src/database'
import { createAuth } from '../src/auth'
import { nativeOAuth, hash } from '../src/native-oauth'
import { NativeAuthError } from '../src/auth-error'
import { authApp } from '../src/auth-app'
import { isPublicAuthPath } from '../src/auth-routes'
import { renderEmail } from '../src/email'

const databaseURL = process.env.TEST_DATABASE_URL
if (!databaseURL) throw new Error('A disposable auth test database is required')
const { db, pool } = connectDatabase(databaseURL)
const origin = 'http://localhost:3199'
const sent: { email: string; kind: string; url: string }[] = []
const auth = createAuth(db, {
  baseURL: origin,
  secret: 'shared-local-auth-test-secret-123456789',
  powerSyncURL: 'https://sync.example.test',
  sendEmail: async (email, kind, url) => {
    sent.push({ email, kind, url })
  }
})
beforeEach(async () => {
  await pool.query('truncate auth_rate_limit, auth_jwks')
  await pool.query(
    "insert into recovery_lease values (1,clock_timestamp(),clock_timestamp(),'shared-auth-test') on conflict (id) do update set snapshot_started_at=clock_timestamp(),verified_at=clock_timestamp()"
  )
})
afterAll(async () => {
  await pool.query('truncate auth_jwks')
  await pool.end()
})
let requestNumber = 0
function request(path: string, body?: unknown, token?: string) {
  return new Request(origin + '/api/auth/' + path, {
    method: body === undefined ? 'GET' : 'POST',
    headers: {
      'content-type': 'application/json',
      'cf-connecting-ip': '192.0.2.' + ((++requestNumber % 250) + 1),
      origin,
      ...(token ? { authorization: 'Bearer ' + token } : {})
    },
    ...(body === undefined ? {} : { body: JSON.stringify(body) })
  })
}
async function account() {
  const email = crypto.randomUUID() + '@example.test'
  const password = 'shared-test-password-123'
  const signup = await auth.handler(
    request('sign-up/email', {
      email,
      password,
      name: 'Shared test',
      callbackURL: authApp.callbackURL
    })
  )
  expect(signup.status).toBe(200)
  expect(
    (
      await auth.handler(
        new Request([...sent].reverse().find((m) => m.email === email)!.url)
      )
    ).status
  ).toBeLessThan(400)
  const signin = await auth.handler(
    request('sign-in/email', { email, password })
  )
  expect(signin.status).toBe(200)
  const token = signin.headers.get('set-auth-token')!
  expect(token).toBeTruthy()
  const session = await auth.api.getSession({
    headers: new Headers({ authorization: 'Bearer ' + token })
  })
  return { email, password, token, id: session!.user.id }
}

test('verified native bearer sessions retain the original UUID and issue short sync tokens', async () => {
  const a = await account()
  const result = await auth.handler(request('token', undefined, a.token))
  expect(result.status).toBe(200)
  const jwt = (await result.json()).token as string
  const claims = JSON.parse(
    Buffer.from(jwt.split('.')[1]!, 'base64url').toString()
  )
  expect(claims).toMatchObject({
    sub: a.id,
    iss: origin,
    aud: 'https://sync.example.test'
  })
  expect(claims.exp - claims.iat).toBe(300)
})

test('password reset is single-use, revokes old sessions and accepts the new password', async () => {
  const a = await account()
  expect(
    (
      await auth.handler(
        request('request-password-reset', {
          email: a.email,
          redirectTo: authApp.callbackURL + '?type=recovery'
        })
      )
    ).status
  ).toBe(200)
  const url = new URL(
    [...sent].reverse().find((m) => m.email === a.email && m.kind === 'reset')!
      .url
  )
  const token = url.pathname.split('/').at(-1)!
  const body = { token, newPassword: 'replacement-password-123' }
  expect((await auth.handler(request('reset-password', body))).status).toBe(200)
  expect(
    (await auth.handler(request('reset-password', body))).status
  ).toBeGreaterThanOrEqual(400)
  expect(
    await auth.api.getSession({
      headers: new Headers({ authorization: 'Bearer ' + a.token })
    })
  ).toBeNull()
  expect(
    (
      await auth.handler(
        request('sign-in/email', { email: a.email, password: body.newPassword })
      )
    ).status
  ).toBe(200)
})

test('unsafe redirects and unapproved auth endpoints are rejected', async () => {
  for (const redirectTo of [
    'https://evil.example',
    '//evil.example',
    '/.//evil.example',
    '/\\evil.example',
    '/\t/evil.example'
  ]) {
    expect(
      (
        await auth.handler(
          request('request-password-reset', {
            email: 'nobody@example.test',
            redirectTo
          })
        )
      ).status
    ).toBe(400)
  }
  for (const path of [
    'admin/create-user',
    'list-users',
    'update-user',
    'reset-password/../../admin'
  ])
    expect(isPublicAuthPath(path)).toBe(false)
  expect(isPublicAuthPath('get-session')).toBe(true)
})

test('native proof codes reject a wrong verifier and cannot be replayed', async () => {
  const a = await account()
  const verifier = 'a'.repeat(64)
  const complete = await nativeOAuth(
    new Request(origin + '/api/native/complete?challenge=' + hash(verifier), {
      headers: { authorization: 'Bearer ' + a.token }
    }),
    auth,
    pool,
    origin
  )
  expect(complete!.status).toBe(302)
  const callback = new URL(complete!.headers.get('location')!)
  expect(callback.protocol).toBe(new URL(authApp.callbackURL).protocol)
  const code = callback.searchParams.get('code')!
  const exchange = (proof: string) =>
    nativeOAuth(
      new Request(origin + '/api/native/exchange', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ code, verifier: proof })
      }),
      auth,
      pool,
      origin
    )
  await expect(exchange('b'.repeat(64))).rejects.toBeInstanceOf(NativeAuthError)
  const exchanged = (await (await exchange(verifier))!.json()) as {
    token: string
  }
  const session = await auth.api.getSession({
    headers: new Headers({ authorization: 'Bearer ' + exchanged.token })
  })
  expect(session?.user.id).toBe(a.id)
  await expect(exchange(verifier)).rejects.toBeInstanceOf(NativeAuthError)
})

test('email links keep each app branding and refuse another origin', () => {
  const rendered = renderEmail(
    'verify',
    origin + '/api/auth/verify-email?token=test',
    origin
  )
  expect(rendered.subject).toContain(authApp.name)
  expect(rendered.htmlContent).toContain(authApp.emailFooter)
  expect(() =>
    renderEmail(
      'reset',
      'https://evil.example/api/auth/reset-password/test',
      origin
    )
  ).toThrow()
})
