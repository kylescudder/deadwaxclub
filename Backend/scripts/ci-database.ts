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
  const owner = identifier(config.ownerRole)
  // The platform creates and grants <db>_runtime. An app may use its own
  // runtime login instead (Deadwax: deadwax_runtime), which only provisionRoles
  // creates and grants, exactly as on Herman.
  const platformRuntime = config.database + '_runtime'
  const runtime = identifier(platformRuntime)
  const admin = new Pool({ connectionString: process.env.DATABASE_URL, max: 1 })
  try {
    // Mirror Herman's platform scripts/provision-project.py so tests start from
    // the shared server's real owner/runtime roles and default privileges.
    for (const role of [config.ownerRole, platformRuntime])
      if (
        !(await admin.query('select 1 from pg_roles where rolname=$1', [role]))
          .rowCount
      )
        await admin.query(
          `create role ${identifier(role)} login nosuperuser nocreatedb nocreaterole noreplication nobypassrls noinherit connection limit 8`
        )
    if (
      !(
        await admin.query('select 1 from pg_database where datname=$1', [
          database
        ])
      ).rowCount
    )
      await admin.query(
        `create database ${identifier(database)} owner ${owner}`
      )
    await admin.query(
      `revoke all on database ${identifier(database)} from public`
    )
    await admin.query(
      `grant connect on database ${identifier(database)} to ${owner}, ${runtime}`
    )
  } finally {
    await admin.end()
  }
  const url = new URL(process.env.DATABASE_URL)
  url.pathname = '/' + database
  urls.push(url.href)
  const platform = new Pool({ connectionString: url.href, max: 1 })
  try {
    for (const statement of [
      'revoke all on schema public from public',
      `alter schema public owner to ${owner}`,
      `grant usage on schema public to ${runtime}`,
      `alter default privileges for role ${owner} in schema public grant select, insert, update, delete on tables to ${runtime}`,
      `alter default privileges for role ${owner} in schema public grant usage, select on sequences to ${runtime}`,
      `alter default privileges for role ${owner} revoke execute on functions from public`
    ])
      await platform.query(statement)
    const client = await platform.connect()
    try {
      await provisionRoles(client, config)
    } finally {
      client.release()
    }
  } finally {
    await platform.end()
  }
  // Production migrations run with the owner credential, never as a superuser.
  const ownerURL = new URL(url.href)
  ownerURL.searchParams.set('options', `-c role=${config.ownerRole}`)
  const { db, pool } = connectDatabase(ownerURL.href)
  try {
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
