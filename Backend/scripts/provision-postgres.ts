import { Pool } from 'pg'
import { deploymentConfig } from './config'
import { provisionRoles, provisionSync, provisionDatabases } from './provision'
const config = await deploymentConfig()
if (!process.env.PROVISION_DATABASE_URL)
  throw new Error(
    'PROVISION_DATABASE_URL must target this app database on Herman shared PostgreSQL'
  )
const pool = new Pool({
  connectionString: process.env.PROVISION_DATABASE_URL,
  max: 1
})
const client = await pool.connect()
try {
  const database = (await client.query('select current_database() as name'))
    .rows[0].name
  if (process.argv[2] === 'databases') {
    if (database !== 'postgres')
      throw new Error(
        'Database creation requires the shared server postgres maintenance database'
      )
    await provisionDatabases(client, config)
  } else if (database !== config.database)
    throw new Error('Provisioning URL targets another database')
  else if (process.argv[2] === 'roles') await provisionRoles(client, config)
  else if (process.argv[2] === 'sync') await provisionSync(client, config)
  else
    throw new Error(
      'Choose databases, roles (before migrations), or sync (after migrations)'
    )
} finally {
  client.release()
  await pool.end()
}
