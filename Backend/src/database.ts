import { Pool } from 'pg'
import { drizzle } from 'drizzle-orm/node-postgres'
import * as schema from './schema'

export function connectDatabase(url: string) {
  const pool = new Pool({
    connectionString: url,
    max: 4,
    statement_timeout: 55_000,
    idle_in_transaction_session_timeout: 55_000
  })
  return { pool, db: drizzle(pool, { schema }) }
}

export type Database = ReturnType<typeof connectDatabase>['db']
