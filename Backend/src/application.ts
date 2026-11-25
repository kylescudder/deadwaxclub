import { isPublicAuthPath } from './auth-routes'
import { NativeAuthError } from './auth-error'
import type { Pool, PoolClient } from 'pg'
import type { Auth } from './auth'
import { UploadError, uploadChange } from './upload'
import { AppleVerificationError } from './apple-verification'
import { libraryAction } from './library'
import { mirrorEntitlement } from './iap'
import { nativeOAuth } from './native-oauth'
import type { NotificationSpool } from './notification-spool'
import { authApp } from './auth-app'
import type { InviteDetails } from './email'

type SendInviteEmail = (email: string, kind: 'invite', url: string, invite: InviteDetails) => Promise<void>
type CollectionInvitation = { status: string, email: string, inviter: string, target: string }


async function asAccount<T>(pool: Pool, userId: string | null, work: (client: PoolClient) => Promise<T>) {
  const client = await pool.connect()
  try {
    await client.query('begin')
    await client.query(userId ? 'set local role deadwax_api' : 'set local role deadwax_anon')
    if (userId) await client.query("select set_config('deadwax.user_id', $1, true)", [userId])
    const result = await work(client)
    await client.query('commit')
    return result
  } catch (error) {
    await client.query('rollback')
    throw error
  } finally {
    client.release()
  }
}

const errorResponse = (code: string, status: number) =>
  Response.json({ code }, { status, headers: { 'cache-control': 'no-store' } })

// The website's list viewer (deadwaxclub.app/l/<token>) reads these from the
// browser. They are unauthenticated, token-gated and send no credentials, so any
// origin may read them.
const publicListPaths = new Set(['/api/public/get_shared_list', '/api/public/get_shared_list_records'])
const publicCORS = {
  'access-control-allow-origin': '*',
  'access-control-allow-methods': 'POST',
  'access-control-allow-headers': 'content-type',
  'access-control-max-age': '86400'
}
function withPublicCORS(response: Response) {
  for (const [key, value] of Object.entries(publicCORS)) response.headers.set(key, value)
  return response
}

export function createApplication(auth: Auth, pool: Pool, origin: string, spool?: NotificationSpool, sendEmail?: SendInviteEmail) {
  // The invite is saved before its email goes out, and stays usable in the
  // app if the email can't be sent.
  async function emailInvitation(invitation: CollectionInvitation, senderID: string) {
    if (!sendEmail) return
    try {
      await sendEmail(invitation.email, 'invite', authApp.invitesURL, { inviter: invitation.inviter, target: invitation.target, senderID })
    } catch {
      // Budget exhausted or Brevo unavailable; the invite is in the app.
    }
  }

  return async (request: Request): Promise<Response> => {
    const { pathname } = new URL(request.url)
    if (publicListPaths.has(pathname)) {
      if (request.method === 'OPTIONS') return withPublicCORS(new Response(null, { status: 204 }))
      return withPublicCORS(await handle(request, pathname))
    }
    return handle(request, pathname)
  }

  async function handle(request: Request, pathname: string): Promise<Response> {
    try {
      if (request.method === 'GET' && pathname === '/health/live') return Response.json({ ok: true })
      if (request.method === 'GET' && pathname === '/api/auth/jwks') return auth.handler(request)
      if (request.method === 'POST' && pathname === '/api/iap/notifications') {
        const body = await request.json() as { signedPayload?: unknown } | null
        await mirrorEntitlement(pool, body?.signedPayload, undefined, spool)
        return Response.json({ accepted: true })
      }

      await pool.query('select public.require_recovery_lease()')
      if (request.method === 'GET' && pathname === '/health/ready') return Response.json({ ok: true })

      if (pathname.startsWith('/api/auth/')) {
        const route = pathname.slice('/api/auth/'.length)
        if (isPublicAuthPath(route)) {
          return auth.handler(request)
        }
        return errorResponse('not_found', 404)
      }

      const oauth = await nativeOAuth(request, auth, pool, origin)
      if (oauth) return oauth


      if (request.method === 'POST' && (pathname === '/api/public/get_shared_list' || pathname === '/api/public/get_shared_list_records')) {
        const body = await request.json() as { token?: unknown } | null
        if (typeof body?.token !== 'string' || !/^[a-z0-9]{12}$/.test(body.token)) {
          return errorResponse('invalid_request', 422)
        }
        const query = pathname.endsWith('/get_shared_list')
          ? 'select * from public.get_shared_list($1)'
          : 'select * from public.get_shared_list_records($1)'
        const rows = await asAccount(pool, null, async (client) => (await client.query(query, [body.token])).rows)
        return Response.json(rows, { headers: { 'cache-control': 'no-store' } })
      }

      const coverPath = pathname.startsWith('/api/covers/') ? decodeURIComponent(pathname.slice('/api/covers/'.length)) : undefined
      const cover = coverPath?.match(/^[\p{L}\p{N}_]+\/[\p{L}\p{N}_]+\/([0-9a-f-]{36})\/(?:primary\.jpg|(?:images|user)\/[a-z0-9.-]+\.jpg)$/u)
      if (request.method === 'GET' && cover) {
        const bytes = await asAccount(pool, null, async (client) =>
          (await client.query('select bytes from public.cover_objects where path = $1', [coverPath])).rows[0]?.bytes
        )
        return bytes ? new Response(bytes, { headers: { 'content-type': 'image/jpeg', 'x-content-type-options': 'nosniff' } }) : errorResponse('not_found', 404)
      }

      const session = await auth.api.getSession({ headers: request.headers })
      if (!session?.user.emailVerified) return errorResponse('sign_in_required', 401)
      const userId = session.user.id
      if (request.method === 'GET' && pathname === '/api/me') {
        const profile = await asAccount(pool, userId, async (client) =>
          (await client.query('select * from public.profiles where id = $1', [userId])).rows[0]
        )
        return profile
          ? Response.json(profile, { headers: { 'cache-control': 'no-store' } })
          : errorResponse('identity_missing', 409)
      }

      if (request.method === 'PUT' && cover) {
        const bytes = Buffer.from(await request.arrayBuffer())
        if (bytes.length < 3 || bytes.length > 5242880 || !bytes.subarray(0, 3).equals(Buffer.from([255, 216, 255]))) {
          return errorResponse('invalid_cover', 422)
        }
        await asAccount(pool, userId, (client) => client.query(
          'insert into public.cover_objects (path, pressing_id, bytes) values ($1, $2, $3) on conflict (path) do update set bytes = excluded.bytes',
          [coverPath, cover[1], bytes]
        ))
        return Response.json({ accepted: true })
      }

      if (request.method === 'DELETE' && pathname === '/api/devices') {
        const body = await request.json() as { apns_token?: unknown } | null
        if (typeof body?.apns_token !== 'string' || !/^[0-9a-f]{32,256}$/.test(body.apns_token)) {
          return errorResponse('invalid_request', 422)
        }
        await asAccount(pool, userId, (client) => client.query(
          'delete from public.device_tokens where user_id = $1 and apns_token = $2',
          [userId, body.apns_token]
        ))
        return Response.json({ accepted: true })
      }

      if (request.method === 'POST' && pathname === '/api/devices') {
        const body = await request.json() as { apns_token?: string, device_name?: string, environment?: string } | null
        if (!body || typeof body.apns_token !== 'string' || !/^[0-9a-f]{32,256}$/.test(body.apns_token) ||
            typeof body.device_name !== 'string' || body.device_name.length > 200 ||
            (body.environment !== 'production' && body.environment !== 'sandbox')) {
          return errorResponse('invalid_request', 422)
        }
        await asAccount(pool, userId, (client) => client.query(
          "insert into public.device_tokens (user_id, apns_token, device_name, bundle_id, environment) values ($1,$2,$3,'com.deadwaxclub.app',$4) on conflict (user_id, apns_token) do update set device_name = excluded.device_name, environment = excluded.environment",
          [userId, body.apns_token, body.device_name, body.environment]
        ))
        return Response.json({ accepted: true })
      }

      if (request.method === 'DELETE' && pathname === '/api/account') {
        await pool.query('delete from public.auth_user where id = $1', [userId])
        return Response.json({ deleted: true })
      }

      if (request.method === 'POST' && pathname === '/api/iap/transactions') {
        const body = await request.json() as { signedTransactionInfo?: unknown } | null
        return Response.json(await mirrorEntitlement(pool, body?.signedTransactionInfo, userId))
      }

      if (request.method === 'POST' && pathname.startsWith('/api/library/')) {
        const body = await request.json()
        const action = pathname.slice('/api/library/'.length)
        const result = await asAccount(pool, userId, (client) =>
          libraryAction(client, action, body)
        )
        if (action === 'invite_to_collection') {
          const invitation = result as CollectionInvitation
          await emailInvitation(invitation, userId)
          return Response.json({ status: invitation.status })
        }
        return Response.json(result)
      }

      if (request.method === 'POST' && pathname === '/api/sync/upload') {
        const change = await request.json()
        await asAccount(pool, userId, (client) => uploadChange(client, change))
        return Response.json({ accepted: true })
      }

      return errorResponse('not_found', 404)
    } catch (error) {
      if (error instanceof NativeAuthError) return errorResponse(error.code, error.status)
      if (error instanceof UploadError) return errorResponse(error.code, error.status)
      if (error instanceof AppleVerificationError) return errorResponse('apple_verification_failed', 422)
      if (error instanceof SyntaxError) return errorResponse('invalid_request', 400)
      const code = error instanceof Error && 'code' in error ? String(error.code) : ''
      // Sharing refusals carry fixed messages written for the app to show.
      if ((code === 'DW004' || code === 'DW005') && error instanceof Error) {
        return Response.json({ code, message: error.message }, { status: code === 'DW005' ? 403 : 422, headers: { 'cache-control': 'no-store' } })
      }
      if (code === '42501') return errorResponse('permission_denied', 403)
      if (['DW001', 'DW002', 'DW003', '23502', '23503', '23505', '23514', '22P02'].includes(code)) {
        return errorResponse(code, 422)
      }
      return errorResponse('temporarily_unavailable', 503)
    }
  }
}
