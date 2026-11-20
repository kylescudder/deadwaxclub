import { createHash, randomBytes } from 'node:crypto'
import type { Pool } from 'pg'
import type { Auth } from './auth'
import { UploadError } from './upload'

export const hash = (value: string) =>
  createHash('sha256').update(value).digest('base64url')
export async function nativeOAuth(
  request: Request,
  auth: Auth,
  pool: Pool,
  origin: string
): Promise<Response | undefined> {
  const url = new URL(request.url)
  if (url.pathname === '/api/native/google' && request.method === 'GET') {
    const challenge = url.searchParams.get('challenge') ?? ''
    if (!/^[A-Za-z0-9_-]{43}$/.test(challenge))
      throw new UploadError('invalid_request', 400, 'Invalid proof key.')
    const response = await auth.api.signInSocial({
      body: {
        provider: 'google',
        callbackURL: `${origin}/api/native/complete?challenge=${challenge}`,
        disableRedirect: true
      },
      headers: request.headers,
      asResponse: true
    })
    if (!response.ok) return response
    const result = (await response.json()) as { url?: string }
    if (!result.url) throw new Error('OAuth unavailable')
    const headers = new Headers(response.headers)
    headers.set('location', result.url)
    return new Response(null, { status: 302, headers })
  }
  if (url.pathname === '/api/native/complete' && request.method === 'GET') {
    const challenge = url.searchParams.get('challenge') ?? ''
    if (!/^[A-Za-z0-9_-]{43}$/.test(challenge))
      throw new UploadError('invalid_request', 400, 'Invalid proof key.')
    const session = await auth.api.getSession({ headers: request.headers })
    if (!session?.user.emailVerified)
      throw new UploadError('DX002', 401, 'Sign in required.')
    const code = randomBytes(32).toString('base64url')
    await pool.query(
      "insert into native_codes values ($1,$2,$3,clock_timestamp() + interval '2 minutes')",
      [hash(code), challenge, session.session.token]
    )
    return Response.redirect(`deadwaxclub://auth-callback?code=${code}`, 302)
  }
  if (url.pathname === '/api/native/exchange' && request.method === 'POST') {
    const { code, verifier } = (await request.json()) as {
      code?: string
      verifier?: string
    }
    if (
      typeof code !== 'string' ||
      typeof verifier !== 'string' ||
      verifier.length < 43 ||
      verifier.length > 128
    )
      throw new UploadError('invalid_request', 400, 'Invalid proof key.')
    // Atomic consumption: concurrent/replayed requests cannot redeem the code.
    const result = await pool.query(
      'delete from native_codes where id = $1 and challenge = $2 and expires_at > clock_timestamp() returning session_token',
      [hash(code), hash(verifier)]
    )
    if (!result.rowCount)
      throw new UploadError(
        'invalid_code',
        401,
        'This sign-in link has expired.'
      )
    return Response.json({ token: result.rows[0].session_token })
  }
}
