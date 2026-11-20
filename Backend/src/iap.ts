import type { Pool } from 'pg'
import {
  dateFromMillis, DEADWAX_ENTITLEMENT_POLICY, entitlementStatus,
  verifyAppleNotification, verifyAppleTransaction
} from './apple-verification'
import { UploadError } from './upload'
import type { NotificationSpool } from './notification-spool'

export async function mirrorEntitlement(
  pool: Pool,
  input: unknown,
  userId?: string,
  spool?: NotificationSpool
) {
  const notification = userId ? undefined : await verifyAppleNotification(input)
  if (notification && spool && typeof input === 'string') await spool.retain(input)
  const transaction = notification?.transaction ?? await verifyAppleTransaction(input)
  if (userId && transaction.appAccountToken !== userId) {
    throw new UploadError('app_account_token_mismatch', 403)
  }
  const expiresAt = dateFromMillis(transaction.expiresDate)
  const revokedAt = dateFromMillis(transaction.revocationDate)
  const status = entitlementStatus(expiresAt, revokedAt, notification?.notificationType)

  await pool.query('select public.require_recovery_lease()')
  const client = await pool.connect()
  try {
    await client.query('begin')
    await client.query('set local role service_role')
    const { rows } = await client.query<{ active: boolean }>(
      `select coalesce((entitlement).status = 'active'
          and (entitlement).expires_at > now() and (entitlement).revoked_at is null, false) as active
        from (select public.apply_verified_iap_entitlement(
          $1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12
        ) as entitlement) as applied`,
      [
        transaction.appAccountToken, transaction.bundleId, transaction.productId,
        transaction.transactionId, transaction.originalTransactionId, status,
        expiresAt, revokedAt, transaction.environment, dateFromMillis(transaction.signedAt),
        new Date(), DEADWAX_ENTITLEMENT_POLICY.verificationSources[notification ? 1 : 0]
      ]
    )
    await client.query('commit')
    return { active: rows[0]?.active ?? false }
  } catch (error) {
    await client.query('rollback')
    throw error
  } finally {
    client.release()
  }
}
