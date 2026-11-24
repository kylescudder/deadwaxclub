import { afterAll, beforeAll, beforeEach, expect, test } from 'bun:test'
import { connectDatabase } from '../src/database'
import { createApplication } from '../src/application'
import { createAuth } from '../src/auth'

const databaseURL = process.env.TEST_DATABASE_URL
if (!databaseURL || new URL(databaseURL).pathname !== '/deadwax_test') {
  throw new Error('Set TEST_DATABASE_URL to a disposable deadwax_test database')
}

const { db, pool } = connectDatabase(databaseURL)
const origin = 'http://localhost:3147'
const verifyLinks = new Map<string, string>()
const auth = createAuth(db, {
  baseURL: origin,
  powerSyncURL: 'https://sync.example.test',
  secret: 'deadwax-disposable-test-secret-only',
  sendEmail: async (email, kind, url) => {
    if (kind === 'verify') verifyLinks.set(email, url)
  }
})
const invites: { email: string, url: string, invite: { inviter: string, target: string } }[] = []
let emailDown = false
const app = createApplication(auth, pool, origin, undefined, async (email, _kind, url, invite) => {
  if (emailDown) throw new Error('Email delivery unavailable')
  invites.push({ email, url, invite })
})

beforeAll(() => pool.query(
  "insert into public.recovery_lease values (1, now(), now(), 'collection-invites-test') on conflict (id) do update set snapshot_started_at = now(), verified_at = now()"
))
beforeEach(() => pool.query('truncate public.auth_rate_limit'))
afterAll(() => pool.end())

function call(path: string, options?: { body?: unknown, token?: string }) {
  const headers = new Headers()
  if (options?.body) headers.set('content-type', 'application/json')
  if (options?.token) headers.set('authorization', 'Bearer ' + options.token)
  return app(new Request(new URL(path, origin), {
    method: options?.body ? 'POST' : 'GET',
    headers,
    body: options?.body ? JSON.stringify(options.body) : undefined
  }))
}

type Account = { email: string, token: string, id: string, collectionID: string }

async function signUp(email: string, name: string) {
  const signup = await call('/api/auth/sign-up/email', { body: { email, password: 'test-only-password', name } })
  expect(signup.status).toBe(200)
}

async function verifyAndSignIn(email: string): Promise<Account> {
  expect((await call(verifyLinks.get(email)!)).status).toBeLessThan(400)
  const signIn = await call('/api/auth/sign-in/email', { body: { email, password: 'test-only-password' } })
  const { token, user } = await signIn.json() as { token: string, user: { id: string } }
  const profile = await (await call('/api/me', { token })).json() as { primary_collection_id: string }
  return { email, token, id: user.id, collectionID: profile.primary_collection_id }
}

async function account(name: string) {
  const email = `${name.toLowerCase()}-${crypto.randomUUID().slice(0, 8)}@example.test`
  await signUp(email, name)
  return verifyAndSignIn(email)
}

const library = (token: string, action: string, body: Record<string, string> = {}) =>
  call('/api/library/' + action, { token, body })

const invite = (owner: Account, email: string, role = 'editor') =>
  library(owner.token, 'invite_to_collection', { p_collection_id: owner.collectionID, p_email: email, p_role: role })

async function incoming(account: Account) {
  const response = await library(account.token, 'get_incoming_collection_invites')
  expect(response.status).toBe(200)
  return await response.json() as { id: string, space_id: string, space_name: string, inviter_name: string, role: string }[]
}

async function role(collectionID: string, userID: string) {
  const row = await pool.query('select role::text from public.collection_members where collection_id = $1 and user_id = $2', [collectionID, userID])
  return row.rows[0]?.role as string | undefined
}

test('an invite to an existing account waits until they accept it in the app', async () => {
  const owner = await account('Owner')
  const invitee = await account('Invitee')
  const stranger = await account('Stranger')

  const invited = await invite(owner, invitee.email.toUpperCase())
  expect(invited.status).toBe(200)
  expect(await invited.json()).toEqual({ status: 'pending' })
  expect(await role(owner.collectionID, invitee.id)).toBeUndefined()
  expect([...invites].reverse().find((m) => m.email === invitee.email)).toEqual({
    email: invitee.email,
    url: 'https://deadwaxclub.app/invites',
    invite: { inviter: 'Owner', target: 'the Collection “Owner\'s Collection”' }
  })
  const notice = await pool.query("select title, body, payload from public.notifications where user_id = $1 and kind = 'collection_invite'", [invitee.id])
  expect(notice.rows).toHaveLength(1)
  expect(notice.rows[0]).toMatchObject({ title: "Owner's Collection", body: 'Owner invited you to this Collection.' })

  const [pending] = await incoming(invitee)
  expect(pending).toMatchObject({ space_id: owner.collectionID, space_name: "Owner's Collection", inviter_name: 'Owner', role: 'editor' })
  expect(await incoming(stranger)).toEqual([])
  const stolen = await library(stranger.token, 'accept_collection_invite', { p_invite_id: pending!.id })
  expect(stolen.status).toBe(422)
  expect(await stolen.json()).toEqual({ code: 'DW004', message: 'This invite is no longer available.' })

  const accepted = await library(invitee.token, 'accept_collection_invite', { p_invite_id: pending!.id })
  expect(accepted.status).toBe(200)
  expect(await accepted.json()).toEqual({ status: 'accepted', space_id: owner.collectionID })
  expect(await role(owner.collectionID, invitee.id)).toBe('editor')
  expect(await incoming(invitee)).toEqual([])
  expect((await library(invitee.token, 'accept_collection_invite', { p_invite_id: pending!.id })).status).toBe(422)

  const again = await invite(owner, invitee.email)
  expect(again.status).toBe(422)
  expect(await again.json()).toEqual({ code: 'DW004', message: 'They already have access.' })
})

test('signing up later no longer joins the Collection: the invite is accepted in the app', async () => {
  const owner = await account('Host')
  const email = `later-${crypto.randomUUID().slice(0, 8)}@example.test`
  expect(await (await invite(owner, email, 'viewer')).json()).toEqual({ status: 'pending' })

  await signUp(email, 'Later')
  const invitee = await verifyAndSignIn(email)
  expect(await role(owner.collectionID, invitee.id)).toBeUndefined()
  expect(invitee.collectionID).toBeString()

  const [pending] = await incoming(invitee)
  expect(pending).toMatchObject({ space_id: owner.collectionID, role: 'viewer' })
  await library(invitee.token, 'accept_collection_invite', { p_invite_id: pending!.id })
  expect(await role(owner.collectionID, invitee.id)).toBe('viewer')
})

test('declining removes the invite, refusals explain themselves, and a failed email keeps the invite', async () => {
  const owner = await account('Keeper')
  const invitee = await account('Guest')
  await invite(owner, invitee.email)
  const [pending] = await incoming(invitee)
  expect((await library(invitee.token, 'decline_collection_invite', { p_invite_id: pending!.id })).status).toBe(200)
  expect(await incoming(invitee)).toEqual([])
  expect((await library(invitee.token, 'accept_collection_invite', { p_invite_id: pending!.id })).status).toBe(422)
  expect(await role(owner.collectionID, invitee.id)).toBeUndefined()

  const notOwner = await library(invitee.token, 'invite_to_collection', { p_collection_id: owner.collectionID, p_email: 'x@example.test', p_role: 'editor' })
  expect(notOwner.status).toBe(403)
  expect((await notOwner.json()).code).toBe('DW005')
  for (const [email, role] of [[owner.email, 'editor'], ['not-an-email', 'editor'], ['friend@example.test', 'owner']] as const) {
    const refused = await invite(owner, email, role)
    expect(refused.status).toBe(422)
    const error = await refused.json() as { code: string, message: string }
    expect(error.code).toBe('DW004')
    expect(error.message.length).toBeGreaterThan(0)
  }

  emailDown = true
  try {
    expect((await invite(owner, invitee.email, 'viewer')).status).toBe(200)
  } finally {
    emailDown = false
  }
  expect((await incoming(invitee)).map((i) => i.role)).toEqual(['viewer'])
})
