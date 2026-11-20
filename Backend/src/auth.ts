import { betterAuth } from 'better-auth'
import { drizzleAdapter } from '@better-auth/drizzle-adapter'
import { APIError, createAuthMiddleware } from 'better-auth/api'
import { bearer, jwt } from 'better-auth/plugins'
import type { Database } from './database'
import * as schema from './auth-schema'
import { authApp } from './auth-app'

export type AuthSettings = {
  baseURL: string
  secret: string
  powerSyncURL: string
  google?: { clientId: string; clientSecret: string }
  apple?: {
    clientId: string
    clientSecret: string
    appBundleIdentifier: string
  }
  sendEmail: (
    email: string,
    kind: 'verify' | 'reset',
    url: string
  ) => Promise<void>
}

export function createAuth(db: Database, settings: AuthSettings) {
  return betterAuth({
    appName: authApp.name,
    baseURL: settings.baseURL,
    basePath: '/api/auth',
    secret: settings.secret,
    trustedOrigins: [settings.baseURL, authApp.callbackURL],
    logger: { disabled: true },
    hooks: {
      before: createAuthMiddleware(async (ctx) => {
        for (const key of [
          'callbackURL',
          'newUserCallbackURL',
          'errorCallbackURL',
          'redirectTo'
        ]) {
          const target = ctx.body?.[key] ?? ctx.query?.[key]
          if (target === undefined) continue
          if (
            typeof target !== 'string' ||
            [...target].some(
              (c) =>
                c.charCodeAt(0) <= 32 || c.charCodeAt(0) === 127 || c === '\\'
            ) ||
            target.startsWith('//')
          )
            throw new APIError('BAD_REQUEST', { message: 'Invalid redirect.' })
          const parsed = new URL(target, settings.baseURL)
          const native =
            parsed.protocol === new URL(authApp.callbackURL).protocol &&
            parsed.host === 'auth-callback' &&
            ['', '/'].includes(parsed.pathname) &&
            !parsed.username &&
            !parsed.password &&
            !parsed.port
          if (
            !native &&
            (parsed.origin !== new URL(settings.baseURL).origin ||
              parsed.pathname.startsWith('//'))
          )
            throw new APIError('BAD_REQUEST', { message: 'Invalid redirect.' })
        }
        if (
          ctx.body?.idToken &&
          (!ctx.body.idToken.nonce || ctx.body.provider !== 'apple')
        )
          throw new APIError('BAD_REQUEST', {
            message: 'Invalid native token.'
          })
      })
    },
    database: drizzleAdapter(db, {
      provider: 'pg',
      transaction: true,
      schema: {
        user: schema.authUser,
        session: schema.authSession,
        account: schema.authAccount,
        verification: schema.authVerification,
        rateLimit: schema.authRateLimit,
        jwks: schema.authJwks
      }
    }),
    advanced: {
      database: { generateId: () => crypto.randomUUID() },
      cookiePrefix: authApp.cookiePrefix,
      useSecureCookies: settings.baseURL.startsWith('https://'),
      ipAddress: { ipAddressHeaders: ['cf-connecting-ip'] }
    },
    session: {
      expiresIn: 7 * 86400,
      updateAge: 86400,
      freshAge: 3600,
      cookieCache: { enabled: false }
    },
    emailAndPassword: {
      enabled: true,
      requireEmailVerification: true,
      minPasswordLength: 6,
      maxPasswordLength: 128,
      resetPasswordTokenExpiresIn: 1800,
      revokeSessionsOnPasswordReset: true,
      password: {
        hash: (password) =>
          Bun.password.hash(password, { algorithm: 'argon2id' }),
        // Bun detects the bcrypt format used by imported Supabase accounts.
        verify: ({ hash, password }) => Bun.password.verify(password, hash)
      },
      sendResetPassword: ({ user, url }) =>
        settings.sendEmail(user.email, 'reset', url)
    },
    emailVerification: {
      sendOnSignUp: true,
      autoSignInAfterVerification: false,
      sendVerificationEmail: ({ user, url }) =>
        settings.sendEmail(user.email, 'verify', url)
    },
    account: { accountLinking: { enabled: false } },
    socialProviders: {
      ...(settings.google ? { google: settings.google } : {}),
      ...(settings.apple ? { apple: settings.apple } : {})
    },
    rateLimit: {
      enabled: true,
      storage: 'database',
      window: 60,
      max: 60,
      customRules: {
        '/sign-in/email': { window: 60, max: 5 },
        '/sign-up/email': { window: 60, max: 3 },
        '/request-password-reset': { window: 60, max: 3 },
        '/reset-password': { window: 60, max: 5 }
      }
    },
    plugins: [
      bearer(),
      jwt({
        jwt: {
          issuer: settings.baseURL,
          audience: settings.powerSyncURL,
          expirationTime: '5m',
          definePayload: ({ user }) => ({ sub: user.id })
        }
      })
    ]
  })
}

export type Auth = ReturnType<typeof createAuth>
