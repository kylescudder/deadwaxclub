import { Pool } from 'pg'

const path = process.argv[2]
const databaseURL = process.env.RECOVERY_DATABASE_URL
if (!path || !databaseURL) throw new Error('A recovery proof and RECOVERY_DATABASE_URL are required')

const proof = await Bun.file(path).json()
const start = Date.parse(proof.snapshotStartedAt)
const verified = Date.parse(proof.verifiedAt)
const now = Date.now()
if (proof.nasVerified !== true || typeof proof.snapshotID !== 'string' || !proof.snapshotID ||
    !Number.isFinite(start) || !Number.isFinite(verified) || verified < start ||
    verified > now || now - start >= 600000) {
  throw new Error('A fresh verified recovery snapshot is required')
}

const pool = new Pool({ connectionString: databaseURL, max: 1 })
try {
  await pool.query(`
    insert into public.recovery_lease values (1, $1, $2, $3)
    on conflict (id) do update set
      snapshot_started_at = excluded.snapshot_started_at,
      verified_at = excluded.verified_at,
      snapshot_id = excluded.snapshot_id
    where recovery_lease.snapshot_started_at <= excluded.snapshot_started_at
  `, [new Date(start), new Date(verified), proof.snapshotID])
} finally {
  await pool.end()
}
