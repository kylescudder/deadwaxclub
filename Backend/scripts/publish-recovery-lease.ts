import { Pool } from 'pg'
import { readFile } from 'node:fs/promises'
import { validateRecoveryProof } from './recovery-proof'
if (!process.argv[2] || !process.env.RECOVERY_DATABASE_URL)
  throw new Error('A proof file and RECOVERY_DATABASE_URL are required')
const proof = validateRecoveryProof(
  JSON.parse(await readFile(process.argv[2], 'utf8'))
)
const pool = new Pool({
  connectionString: process.env.RECOVERY_DATABASE_URL,
  max: 1
})
try {
  await pool.query(
    'insert into public.recovery_lease values(1,$1,$2,$3) on conflict(id) do update set snapshot_started_at=excluded.snapshot_started_at,verified_at=excluded.verified_at,snapshot_id=excluded.snapshot_id where recovery_lease.snapshot_started_at <= excluded.snapshot_started_at',
    [proof.snapshotStartedAt, proof.verifiedAt, proof.snapshotID]
  )
} finally {
  await pool.end()
}
