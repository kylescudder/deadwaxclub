import type { Pool } from 'pg'
import { authApp } from './auth-app'

const escape = (value: string) =>
  value.replace(
    /[&<>"']/g,
    (c) =>
      ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[
        c
      ]!
  )

export type EmailKind = 'verify' | 'reset' | 'invite'

/// Who invited the recipient and to what, e.g. "Sam" and "the trip “Lisbon”".
/// `senderID` is the inviting account, whose invite mail is capped per day.
export type InviteDetails = {
  inviter: string
  target: string
  senderID: string
}

/// Invite mail one account may send a day, however its invites change.
export const inviteSenderDailyLimit = 20

// Invite text comes from other users: keep it to one short line.
const plain = (value: string, max: number) =>
  Array.from(value, (c) =>
    c.charCodeAt(0) < 32 || c.charCodeAt(0) === 127 ? ' ' : c
  )
    .join('')
    .replace(/ {2,}/g, ' ')
    .trim()
    .slice(0, max)

// Apps that send sharing invites set `invitesURL` in auth-app.ts: the page
// that opens the app's invite list. Invite mail may link only there.
const invitesURL = () => (authApp as { invitesURL?: string }).invitesURL

export function renderEmail(
  kind: EmailKind,
  url: string,
  origin: string,
  invite?: InviteDetails
) {
  const link = new URL(url)
  if (kind === 'invite') {
    const target = invitesURL()
    if (!target || !invite || link.href !== new URL(target).href)
      throw new Error('Invalid email link')
    const inviter = plain(invite.inviter, 60) || 'Someone'
    const title = `${inviter} invited you to ${plain(invite.target, 120)}`
    return {
      subject: `${title} on ${authApp.name}`,
      htmlContent: `<table role="presentation" style="width:100%;font-family:Arial,sans-serif"><tr><td style="padding:32px;text-align:center"><h1>${escape(title)}</h1><p>Open ${escape(authApp.name)} signed in with this email address and accept it under Invites.</p><p><a href="${escape(link.href)}">Open invites</a></p><p>If you weren't expecting this, ignore this email.</p><p>${escape(authApp.emailFooter)}</p></td></tr></table>`
    }
  }
  if (
    link.origin !== origin ||
    !['/api/auth/verify-email', '/api/auth/reset-password/'].some((p) =>
      link.pathname.startsWith(p)
    )
  )
    throw new Error('Invalid email link')
  const title =
    kind === 'verify'
      ? `Confirm your ${authApp.name} account`
      : `Reset your ${authApp.name} password`
  return {
    subject: title,
    htmlContent: `<table role="presentation" style="width:100%;font-family:Arial,sans-serif"><tr><td style="padding:32px;text-align:center"><h1>${title}</h1><p><a href="${escape(link.href)}">${title}</a></p><p>If you did not request this, ignore this email.</p><p>${escape(authApp.emailFooter)}</p></td></tr></table>`
  }
}

export function createEmailSender(
  pool: Pool,
  settings: { key: string; from: string; origin: string; dailyLimit: number },
  send: typeof fetch = fetch
) {
  return async (
    email: string,
    kind: EmailKind,
    url: string,
    invite?: InviteDetails
  ) => {
    const rendered = renderEmail(kind, url, settings.origin, invite)
    const hash = (value: string) =>
      new Bun.CryptoHasher('sha256').update(value).digest('hex')
    const recipientKey = hash(email.trim().toLowerCase())
    const client = await pool.connect()
    try {
      await client.query('begin')
      // One lock per app serializes its budget and prevents parallel overspend.
      await client.query('select pg_advisory_xact_lock(hashtext($1))', [
        authApp.emailBudgetKey
      ])
      // Invite mail can never crowd out sign-in and reset mail: invites use
      // at most half of the app's daily budget, have their own recipient
      // limits, and each sender has a daily cap counted here, where revoking
      // or re-sending an invite can't reset it.
      const limits =
        kind === 'invite'
          ? [
              { key: 'day', seconds: 86400, max: settings.dailyLimit },
              {
                key: 'invite:day',
                seconds: 86400,
                max: Math.floor(settings.dailyLimit / 2)
              },
              {
                key: 'invite-sender:' + hash(invite!.senderID) + ':day',
                seconds: 86400,
                max: inviteSenderDailyLimit
              },
              { key: recipientKey + ':invite:day', seconds: 86400, max: 3 },
              { key: recipientKey + ':invite:minute', seconds: 60, max: 1 }
            ]
          : [
              { key: 'day', seconds: 86400, max: settings.dailyLimit },
              { key: recipientKey + ':hour', seconds: 3600, max: 5 },
              { key: recipientKey + ':minute', seconds: 60, max: 1 }
            ]
      for (const limit of limits) {
        const row = (
          await client.query(
            "select count from auth_email_limit where key = $1 and window_started_at > clock_timestamp() - $2 * interval '1 second'",
            [limit.key, limit.seconds]
          )
        ).rows[0]
        if (row && row.count >= limit.max) {
          await client.query('rollback')
          if (limit.key === 'day')
            throw new Error('Daily email budget exhausted')
          return
        }
      }
      const response = await send('https://api.brevo.com/v3/smtp/email', {
        method: 'POST',
        headers: {
          'api-key': settings.key,
          'content-type': 'application/json'
        },
        body: JSON.stringify({
          sender: { email: settings.from, name: authApp.name },
          to: [{ email }],
          ...rendered
        }),
        signal: AbortSignal.timeout(8000)
      })
      if (!response.ok) throw new Error('Email delivery unavailable')
      for (const limit of limits)
        await client.query(
          "insert into auth_email_limit values ($1,1,clock_timestamp()) on conflict (key) do update set count = case when auth_email_limit.window_started_at <= clock_timestamp() - $2 * interval '1 second' then 1 else auth_email_limit.count + 1 end, window_started_at = case when auth_email_limit.window_started_at <= clock_timestamp() - $2 * interval '1 second' then clock_timestamp() else auth_email_limit.window_started_at end",
          [limit.key, limit.seconds]
        )
      await client.query('commit')
    } catch (error) {
      await client.query('rollback')
      throw error
    } finally {
      client.release()
    }
  }
}
