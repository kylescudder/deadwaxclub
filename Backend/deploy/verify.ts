const live = await fetch('http://127.0.0.1:3147/health/live', {
  signal: AbortSignal.timeout(5000)
})
if (!live.ok) throw new Error('API liveness failed')
const response = await fetch('http://127.0.0.1:3147/health/ready', {
  signal: AbortSignal.timeout(5000)
})
if (!response.ok) throw new Error('API readiness/recovery proof failed')
const jwks = await fetch('http://127.0.0.1:3147/api/auth/jwks', {
  signal: AbortSignal.timeout(5000)
})
if (!jwks.ok || !((await jwks.json()) as { keys: unknown[] }).keys.length)
  throw new Error('JWKS unavailable')
console.log('API readiness and JWKS passed')
