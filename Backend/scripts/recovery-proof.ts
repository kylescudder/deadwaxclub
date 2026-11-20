import { readFile } from 'node:fs/promises'
export type RecoveryProof = {
  snapshotStartedAt: string
  verifiedAt: string
  snapshotID: string
  nasVerified: true
}
export function validateRecoveryProof(
  value: unknown,
  now = Date.now()
): RecoveryProof {
  if (!value || typeof value !== 'object')
    throw new Error('Invalid recovery proof')
  const proof = value as Record<string, unknown>
  const keys = ['snapshotStartedAt', 'verifiedAt', 'snapshotID', 'nasVerified']
  if (
    Object.keys(proof).length !== keys.length ||
    !keys.every((key) => Object.hasOwn(proof, key)) ||
    proof.nasVerified !== true ||
    typeof proof.snapshotID !== 'string' ||
    !proof.snapshotID.trim()
  )
    throw new Error('Invalid recovery proof')
  const parse = (value: unknown) =>
    typeof value === 'string' &&
    /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/.test(
      value
    )
      ? Date.parse(value)
      : NaN
  const start = parse(proof.snapshotStartedAt),
    verified = parse(proof.verifiedAt)
  if (
    !Number.isFinite(start) ||
    !Number.isFinite(verified) ||
    start > now ||
    verified > now ||
    verified < start ||
    now - start >= 600_000
  )
    throw new Error('Recovery proof is not fresh')
  return proof as RecoveryProof
}

if (import.meta.main) {
  if (!process.argv[2])
    throw new Error('A verified off-host recovery proof file is required')
  validateRecoveryProof(JSON.parse(await readFile(process.argv[2], 'utf8')))
  console.log('Verified fresh off-host recovery evidence')
}
