const routes = new Set([
  'sign-in/email',
  'sign-up/email',
  'sign-in/social',
  'sign-out',
  'get-session',
  'verify-email',
  'send-verification-email',
  'request-password-reset',
  'reset-password',
  'change-password',
  'jwks',
  'token',
  'callback/google',
  'callback/apple'
])

export function isPublicAuthPath(path: string): boolean {
  return routes.has(path) || /^reset-password\/[A-Za-z0-9_-]+$/.test(path)
}
