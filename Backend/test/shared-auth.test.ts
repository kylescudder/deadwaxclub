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

test('invite mail links only to the app invites page and keeps sender text to one line', () => {
  const page = (authApp as { invitesURL?: string }).invitesURL
  const details = {
    inviter: 'Sam\r\nBcc: x',
    target: 'the trip “<b>Lisbon</b>”'
  }
  if (!page) {
    // Apps without sharing never send invite mail.
    expect(() =>
      renderEmail('invite', origin + '/invites', origin, details)
    ).toThrow('Invalid email link')
    return
  }
  const rendered = renderEmail('invite', page, origin, details)
  expect(rendered.subject).toBe(
    `Sam Bcc: x invited you to the trip “<b>Lisbon</b>” on ${authApp.name}`
  )
  expect(rendered.htmlContent).toContain('&lt;b&gt;Lisbon&lt;/b&gt;')
  expect(rendered.htmlContent).not.toContain('<b>Lisbon')
  expect(rendered.htmlContent).toContain(authApp.emailFooter)
  expect(() =>
    renderEmail('invite', 'https://evil.example/invites', origin, details)
  ).toThrow('Invalid email link')
  expect(() => renderEmail('invite', page, origin)).toThrow(
    'Invalid email link'
  )
})

test('invites to someone never use up their sign-in email limits', async () => {
  const page = (authApp as { invitesURL?: string }).invitesURL
  if (!page) return
  const { createEmailSender } = await import('../src/email')
  let sends = 0
  const send = (async () => {
    sends++
    return new Response(null, { status: 201 })
  }) as unknown as typeof fetch
  const sender = createEmailSender(
    pool,
    { key: 'test-only', from: 'hello@example.test', origin, dailyLimit: 1000 },
    send
  )
  const email = crypto.randomUUID() + '@example.test'
  const details = { inviter: 'Sam', target: 'a test' }
  await sender(email, 'invite', page, details)
  // A second invite inside the minute is dropped silently.
  await sender(email, 'invite', page, details)
  expect(sends).toBe(1)
  // Their own verification mail still goes out.
  await sender(email, 'verify', origin + '/api/auth/verify-email?token=t')
  expect(sends).toBe(2)
})

test('native Apple names initialize profiles and returning sign-ins preserve user edits', async () => {
  const appleAuth = createAuth(db, {
    baseURL: origin,
    secret: 'shared-local-auth-test-secret-123456789',
    powerSyncURL: 'https://sync.example.test',
    // Only the external Apple verification boundary is stubbed. Exercise the
    // real Better Auth name mapping and each application's profile triggers.
    apple: Object.assign(
      { clientId: 'test', clientSecret: 'test', appBundleIdentifier: 'test' },
      { verifyIdToken: async () => true }
    ),
    sendEmail: async () => {}
  })
  const subject = crypto.randomUUID()
  const claims = {
    sub: subject,
    email: subject + '@example.test',
    email_verified: true
  }
  const token =
    Buffer.from('{"alg":"RS256"}').toString('base64url') +
    '.' +
    Buffer.from(JSON.stringify(claims)).toString('base64url') +
    '.test'
  const signIn = async (name?: string) => {
    const response = await appleAuth.handler(
      request('sign-in/social', {
        provider: 'apple',
        idToken: {
          token,
          nonce: 'test-nonce',
          ...(name ? { user: { name: { firstName: name } } } : {})
        }
      })
    )
    expect(response.status).toBe(200)
    return (await response.json()) as {
      token: string
      user: { id: string; name: string }
    }
  }
  const first = await signIn('Taylor')
  expect(first.user.name).toBe('Taylor')
  const profileName = async () =>
    (
      await pool.query('select display_name from profiles where id = $1', [
        first.user.id
      ])
    ).rows[0]?.display_name
  expect(await profileName()).toBe('Taylor')
  // Model a name chosen in Settings before another Apple authorization.
  await pool.query('update profiles set display_name = $2 where id = $1', [
    first.user.id,
    'My chosen name'
  ])
  expect((await signIn()).user.id).toBe(first.user.id)
  expect(await profileName()).toBe('My chosen name')
  expect((await signIn('Different Apple name')).user.id).toBe(first.user.id)
  expect(await profileName()).toBe('My chosen name')
})
