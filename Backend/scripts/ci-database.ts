import { Pool } from 'pg'
import { appendFile } from 'node:fs/promises'
import { deploymentConfig, identifier } from './config'
import { provisionRoles } from './provision'
import { connectDatabase } from '../src/database'
import { migrateDeployment } from './infra-migrations'
import { migrateApplication } from '../db/application'
if (!process.env.DATABASE_URL)
  throw new Error('Disposable CI DATABASE_URL required')
const config = await deploymentConfig()
const urls: string[] = []
for (const database of [
  config.project + '_test',
  config.project + '_infra_test'
]) {
  const admin = new Pool({ connectionString: process.env.DATABASE_URL, max: 1 })
  try {
    if (
      !(
        await admin.query('select 1 from pg_database where datname=$1', [
          database
        ])
      ).rowCount
    )
      await admin.query(`create database ${identifier(database)}`)
  } finally {
    await admin.end()
  }
  const url = new URL(process.env.DATABASE_URL)
  url.pathname = '/' + database
  urls.push(url.href)
  const { db, pool } = connectDatabase(url.href)
  try {
    const client = await pool.connect()
    try {
      await provisionRoles(client, config)
    } finally {
      client.release()
    }
    await migrateDeployment(db, pool, migrateApplication)
  } finally {
    await pool.end()
  }
}
if (process.env.GITHUB_ENV)
  await appendFile(
    process.env.GITHUB_ENV,
    `TEST_DATABASE_URL=${urls[0]}\nDEADWAX_TEST_DATABASE_URL=${urls[0]}\nINFRA_TEST_DATABASE_URL=${urls[1]}\n`
  )
console.log(
  'Separate disposable application and infrastructure databases migrated'
)
