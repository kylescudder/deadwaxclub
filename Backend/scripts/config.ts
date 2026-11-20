import { readFile } from 'node:fs/promises'
export type DeploymentConfig = {
  project: string
  database: string
  ownerRole: string
  runtimeRole: string
  runtimeDefaultRole: string
  apiRole: string
  anonymousRole?: string
  serviceRole?: string
  recoveryRole: string
  syncRole: string
  syncStorageRole: string
  syncStorageDatabase: string
  recoveryTables: string[]
  syncTables: string[]
  deployURL: string
  signatureHeader: string
  receiverHeader: string
}
export function identifier(value: string): string {
  if (!/^[a-z][a-z0-9_]{0,62}$/.test(value))
    throw new Error('Invalid deployment identifier')
  return '"' + value + '"'
}
export async function deploymentConfig(): Promise<DeploymentConfig> {
  const config = JSON.parse(
    await readFile(new URL('../deploy/app.json', import.meta.url), 'utf8')
  ) as DeploymentConfig
  for (const key of [
    'database',
    'ownerRole',
    'runtimeRole',
    'runtimeDefaultRole',
    'apiRole',
    'anonymousRole',
    'serviceRole',
    'recoveryRole',
    'syncRole',
    'syncStorageRole',
    'syncStorageDatabase'
  ] as const) {
    if (config[key]) identifier(config[key]!)
  }
  for (const name of [...config.recoveryTables, ...config.syncTables])
    identifier(name)
  if (!/^[a-z][a-z0-9-]+$/.test(config.project))
    throw new Error('Invalid project')
  const roles = [
    config.ownerRole,
    config.runtimeRole,
    config.apiRole,
    config.anonymousRole,
    config.serviceRole,
    config.recoveryRole,
    config.syncRole,
    config.syncStorageRole
  ].filter(Boolean)
  if (
    new Set(roles).size !== roles.length ||
    roles.some((role) =>
      ['anon', 'authenticated', 'service_role', 'postgres'].includes(role!)
    )
  )
    throw new Error('Deployment requires distinct app-scoped roles')
  return config
}
