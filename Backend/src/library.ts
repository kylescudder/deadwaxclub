import type { PoolClient } from 'pg'
import { UploadError } from './upload'

const calls = {
  remove_collection_member: {
    keys: ['parent_id', 'user_id'],
    sql: 'delete from public.collection_members where collection_id = $1 and user_id = $2'
  },
  remove_list_member: {
    keys: ['parent_id', 'user_id'],
    sql: 'delete from public.list_members where list_id = $1 and user_id = $2'
  },
  set_initial_display_name: {
    keys: ['name'],
    sql: "update public.profiles set display_name = $1 where id = identity.user_id() and coalesce(trim(display_name), '') = ''"
  },
  invite_to_collection: {
    keys: ['p_collection_id', 'p_email', 'p_role'],
    sql: 'select public.invite_to_collection($1, $2, $3) as result',
    scalar: true
  },
  invite_to_list: {
    keys: ['p_list_id', 'p_email', 'p_role'],
    sql: 'select public.invite_to_list($1, $2, $3) as result',
    scalar: true
  },
  get_collection_member_profiles: {
    keys: ['p_collection_id'],
    sql: 'select * from public.get_collection_member_profiles($1)'
  },
  revoke_collection_invite: {
    keys: ['p_invite_id'],
    sql: 'select public.revoke_collection_invite($1) as result',
    scalar: true
  },
  revoke_pending_invite: {
    keys: ['p_invite_id'],
    sql: 'select public.revoke_pending_invite($1) as result',
    scalar: true
  },
  get_record_creation_status: {
    keys: [],
    sql: 'select lifetime_record_count::integer, free_limit, has_verified_entitlement from public.get_record_creation_status()'
  }
} satisfies Record<string, { keys: string[]; sql: string; scalar?: boolean }>

export async function libraryAction(
  client: PoolClient,
  name: string,
  input: unknown
) {
  if (!Object.hasOwn(calls, name)) throw new UploadError('not_found', 404)
  if (!input || typeof input !== 'object' || Array.isArray(input)) {
    throw new UploadError('invalid_request', 422)
  }
  const definition = calls[name as keyof typeof calls]
  const body = input as Record<string, unknown>
  const values = definition.keys.map((key) => {
    if (typeof body[key] !== 'string')
      throw new UploadError('invalid_request', 422)
    return body[key]
  })
  const { rows } = await client.query(definition.sql, values)
  return 'scalar' in definition ? (rows[0]?.result ?? null) : rows
}
