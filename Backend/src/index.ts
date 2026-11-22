import { createApplication } from './application'
import { createAuth } from './auth'
import { connectDatabase } from './database'
import { createEmailSender } from './email'
import { mirrorEntitlement } from './iap'
import { NotificationSpool } from './notification-spool'

function required(name: string) {
  const value = process.env[name]
  if (!value) throw new Error(`Missing ${name}`)
  return value
}

function origin(name: string) {
  const value = required(name)
  const url = new URL(value)
  if (url.origin !== value || url.protocol !== 'https:')
    throw new Error(`Invalid ${name}`)
  return value
}

const baseURL = origin('BETTER_AUTH_URL')
const spool = new NotificationSpool(required('NOTIFICATION_SPOOL'))
const { db, pool } = connectDatabase(required('DATABASE_URL'))
const auth = createAuth(db, {
  baseURL,
  secret: required('BETTER_AUTH_SECRET'),
  powerSyncURL: origin('POWERSYNC_URL'),
  google: {
    clientId: required('GOOGLE_CLIENT_ID'),
    clientSecret: required('GOOGLE_CLIENT_SECRET')
  },
  apple: {
    clientId: required('APPLE_CLIENT_ID'),
    clientSecret: required('APPLE_CLIENT_SECRET'),
    appBundleIdentifier: 'com.deadwaxclub.app'
  },
  sendEmail: createEmailSender(pool, {
    key: required('BREVO_API_KEY'),
    from: required('AUTH_EMAIL_FROM'),
    origin: baseURL,
    dailyLimit: 40
  })
})

const server = Bun.serve({
  hostname: '0.0.0.0',
  port: 3147,
  maxRequestBodySize: 5 * 1024 * 1024,
  fetch: createApplication(auth, pool, baseURL, spool)
})
let replaying = false
const replay = setInterval(async () => {
  if (replaying) return
  replaying = true
  try {
    await spool.replay(async (payload) => {
      await mirrorEntitlement(pool, payload)
    })
  } catch {
    // The signed payload remains available for the next pass.
  } finally {
    replaying = false
  }
}, 30000)

process.on('SIGTERM', async () => {
  clearInterval(replay)
  await server.stop()
  await pool.end()
})
