import type { PoolClient } from 'pg'
import { identifier, type DeploymentConfig } from './config'
async function provisionRolesBody(
  client: PoolClient,
  config: DeploymentConfig
) {
  const roles = [
    config.runtimeRole,
    config.apiRole,
    config.anonymousRole,
    config.serviceRole,
    config.recoveryRole
  ].filter(Boolean) as string[]
  for (const role of roles) {
    identifier(role)
    if (['anon', 'authenticated', 'service_role', 'postgres'].includes(role))
      throw new Error('Use app-scoped roles')
    const existing = (
      await client.query(
        'select rolsuper,rolcreatedb,rolcreaterole,rolreplication,rolbypassrls,rolcanlogin,rolinherit from pg_roles where rolname=$1',
        [role]
      )
    ).rows[0]
    if (!existing)
      await client.query(
        `create role ${identifier(role)} ${role === config.runtimeRole ? 'login noinherit connection limit 8' : 'nologin'} nosuperuser nocreatedb nocreaterole noreplication nobypassrls`
      )
    else {
      if (
        [
          'rolsuper',
          'rolcreatedb',
          'rolcreaterole',
          'rolreplication',
          'rolbypassrls'
        ].some((key) => existing[key])
      )
        throw new Error('Existing app role has administrative privileges')
      if (
        existing.rolcanlogin !== (role === config.runtimeRole) ||
        (role === config.runtimeRole && existing.rolinherit)
      )
        throw new Error(
          'Runtime must be LOGIN NOINHERIT and request/recovery roles must be NOLOGIN'
        )
    }
  }
  if (config.anonymousRole && config.serviceRole) {
    for (const legacy of ['anon', 'authenticated', 'service_role']) {
      const member = await client.query(
        'select 1 from pg_auth_members m join pg_roles parent on parent.oid=m.roleid join pg_roles child on child.oid=m.member where parent.rolname=$1 and child.rolname=$2',
        [legacy, config.runtimeRole]
      )
      if (member.rowCount)
        await client.query(
          `revoke ${identifier(legacy)} from ${identifier(config.runtimeRole)}`
        )
    }
  }
  const database = (await client.query('select current_database() as name'))
    .rows[0].name as string
  await client.query(
    `grant connect on database ${identifier(database)} to ${identifier(config.runtimeRole)}`
  )
  // Herman's platform provisioning gives <db>_runtime direct rights on every new
  // table and sequence by default. Remove that default before migrations so the
  // runtime gets only the grants each app's migrations make, and can never write
  // tables such as recovery_lease. Existing explicit grants are left alone.
  if (
    (
      await client.query('select 1 from pg_roles where rolname=$1', [
        config.ownerRole
      ])
    ).rowCount
  )
    for (const kind of ['tables', 'sequences'])
      await client.query(
        `alter default privileges for role ${identifier(config.ownerRole)} in schema public revoke all on ${kind} from ${identifier(config.runtimeRole)}`
      )
  // The platform revokes schema access from PUBLIC and grants USAGE only to its
  // own <db>_runtime login. The app runtime login (Better Auth queries run as it)
  // and each app-scoped request and recovery role need explicit USAGE; table
  // rights still come from migrations.
  await client.query(
    `grant usage on schema public to ${roles.map(identifier).join(', ')}`
  )
  const groups = roles.filter(
    (role) => role !== config.runtimeRole && role !== config.recoveryRole
  )
  const unexpected = await client.query(
    'select parent.rolname from pg_auth_members m join pg_roles parent on parent.oid=m.roleid join pg_roles child on child.oid=m.member where child.rolname=$1 and not(parent.rolname=any($2::text[]))',
    [config.runtimeRole, groups]
  )
  if (unexpected.rowCount)
    throw new Error(
      'Runtime has unexpected role memberships; operator review required'
    )
  for (const role of groups) {
    if (
      (
        await client.query(
          'select 1 from pg_auth_members where member=(select oid from pg_roles where rolname=$1)',
          [role]
        )
      ).rowCount
    )
      throw new Error('App request role has unexpected inherited memberships')
    await client.query(
      `grant ${identifier(role)} to ${identifier(config.runtimeRole)}`
    )
  }
}
async function provisionSyncBody(client: PoolClient, config: DeploymentConfig) {
  if (
    (await client.query("select current_setting('wal_level') as value")).rows[0]
      .value !== 'logical'
  )
    throw new Error(
      'Coordinate logical WAL on the shared server first; this command never changes server settings'
    )
  const role = identifier(config.syncRole)
  const existing = (
    await client.query(
      'select rolreplication,rolbypassrls,rolsuper,rolcreatedb,rolcreaterole from pg_roles where rolname=$1',
      [config.syncRole]
    )
  ).rows[0]
  if (!existing)
    await client.query(
      `create role ${role} login noinherit connection limit 8 replication bypassrls nosuperuser nocreatedb nocreaterole`
    )
  else if (
    !existing.rolreplication ||
    !existing.rolbypassrls ||
    existing.rolsuper ||
    existing.rolcreatedb ||
    existing.rolcreaterole
  )
    throw new Error('Unexpected sync role attributes')
  if (
    (
      await client.query(
        'select 1 from pg_auth_members where member=(select oid from pg_roles where rolname=$1)',
        [config.syncRole]
      )
    ).rowCount
  )
    throw new Error('Sync role has unexpected inherited memberships')
  await client.query(
    `grant connect on database ${identifier(config.database)} to ${role}`
  )
  await client.query(`grant usage on schema public to ${role}`)
  for (const schema of ['public', 'auth']) {
    if (
      (
        await client.query('select 1 from pg_namespace where nspname=$1', [
          schema
        ])
      ).rowCount
    ) {
      await client.query(
        `revoke all privileges on all tables in schema ${schema} from ${role}`
      )
    }
  }
  // Table privileges are allowlisted; no auth tables or other app schemas are granted.
  const tables = config.syncTables
    .map((table) => 'public.' + identifier(table))
    .join(', ')
  await client.query(`grant select on ${tables} to ${role}`)
  const exists = (
    await client.query("select 1 from pg_publication where pubname='powersync'")
  ).rowCount
  await client.query(
    `${exists ? 'alter publication powersync set' : 'create publication powersync for'} table ${tables}`
  )
}
export async function provisionDatabases(
  client: PoolClient,
  config: DeploymentConfig
) {
  for (const name of [config.ownerRole, config.syncStorageRole]) {
    const exists = (
      await client.query(
        'select rolsuper,rolcreatedb,rolcreaterole,rolreplication,rolbypassrls from pg_roles where rolname=$1',
        [name]
      )
    ).rows[0]
    if (!exists)
      await client.query(
        // Matches Herman's platform login roles: NOINHERIT, eight connections.
        `create role ${identifier(name)} login noinherit connection limit 8 nosuperuser nocreatedb nocreaterole noreplication nobypassrls`
      )
    else if (Object.values(exists).some(Boolean))
      throw new Error('Existing database owner has administrative privileges')
  }
  for (const [database, owner] of [
    [config.database, config.ownerRole],
    [config.syncStorageDatabase, config.syncStorageRole]
  ]) {
    const existing = (
      await client.query(
        'select pg_get_userbyid(datdba) as owner from pg_database where datname=$1',
        [database]
      )
    ).rows[0]
    if (!existing)
      await client.query(
        `create database ${identifier(database)} owner ${identifier(owner)}`
      )
    else if (existing.owner !== owner)
      throw new Error(
        'Existing database owner differs; inspect the host inventory before proceeding'
      )
    await client.query(
      `revoke connect on database ${identifier(database)} from public`
    )
  }
}

async function inTransaction(client: PoolClient, action: () => Promise<void>) {
  await client.query('begin')
  try {
    await action()
    await client.query('commit')
  } catch (error) {
    await client.query('rollback')
    throw error
  }
}
export async function provisionRoles(
  client: PoolClient,
  config: DeploymentConfig
) {
  await inTransaction(client, () => provisionRolesBody(client, config))
}
export async function provisionSync(
  client: PoolClient,
  config: DeploymentConfig
) {
  await inTransaction(client, () => provisionSyncBody(client, config))
}
