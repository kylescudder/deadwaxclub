import { connectDatabase } from '../src/database'
import { migrateApplication } from '../db/application'
import { migrateDeployment } from './infra-migrations'
if (!process.env.DATABASE_URL) throw new Error('DATABASE_URL is required')
const { db, pool } = connectDatabase(process.env.DATABASE_URL)
try {
  await migrateDeployment(db, pool, migrateApplication)
} finally {
  await pool.end()
}
