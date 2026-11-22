import type { PoolClient } from 'pg'

const fields = {
  profiles: ['display_name', 'primary_collection_id'],
  records: [
    'record_pressing_id',
    'collection_id',
    'status',
    'notes',
    'created_at',
    'deleted_at'
  ],
  albums: ['dedupe_key', 'title', 'artist', 'album_year', 'created_at'],
  record_pressings: [
    'album_id',
    'dedupe_key',
    'year',
    'colourway',
    'cover_art_source_url',
    'cover_art_storage_path',
    'discogs_release_id',
    'barcode',
    'estimated_price_cents',
    'estimated_price_currency',
    'estimated_price_updated_at',
    'created_at'
  ],
  price_entries: [
    'record_id',
    'owner_id',
    'collection_id',
    'price_cents',
    'currency',
    'shop_name',
    'scanned_at',
    'created_at',
    'deleted_at'
  ],
  record_images: [
    'record_id',
    'collection_id',
    'kind',
    'position',
    'source_url',
    'storage_path',
    'uploaded_by',
    'created_at'
  ],
  collections: ['name', 'created_by', 'created_at', 'deleted_at'],
  notifications: ['read_at'],
  lists: [
    'owner_id',
    'name',
    'description',
    'share_mode',
    'share_token',
    'cover_record_id',
    'created_at',
    'deleted_at'
  ],
  list_items: ['list_id', 'record_id', 'added_by', 'position', 'created_at']
} satisfies Record<string, string[]>

const immutable = new Set([
  'owner_id',
  'created_by',
  'uploaded_by',
  'added_by',
  'created_at'
])
const deletable = new Set(['list_items', 'record_images'])
const updateOnly = new Set(['profiles', 'notifications'])
const uuid = /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i

export class UploadError extends Error {
  constructor(
    readonly code: string,
    readonly status: number,
    message = code
  ) {
    super(message)
  }
}

function isObject(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
}

export async function uploadChange(client: PoolClient, input: unknown) {
  if (!isObject(input)) throw new UploadError('invalid_request', 422)
  const { id, table, op, data } = input
  if (
    typeof table !== 'string' ||
    !Object.hasOwn(fields, table) ||
    typeof id !== 'string' ||
    !uuid.test(id) ||
    (op !== 'put' && op !== 'patch' && op !== 'delete') ||
    !isObject(data)
  )
    throw new UploadError('invalid_request', 422)

  if (op === 'delete') {
    if (!deletable.has(table)) throw new UploadError('invalid_request', 422)
    // A previous attempt can have committed before its response was received.
    await client.query(`delete from public.${table} where id = $1`, [id])
    return
  }

  const keys = fields[table as keyof typeof fields].filter((key) =>
    Object.hasOwn(data, key)
  )
  const update = keys.filter((key) => !immutable.has(key))
  const existing = await client.query(
    `select id from public.${table} where id = $1`,
    [id]
  )
  if (existing.rowCount) {
    if (table === 'records' && op === 'put') return
    if (update.length) {
      const result = await client.query(
        `update public.${table} set ${update.map((key, index) => `${key} = $${index + 2}`).join(', ')} where id = $1`,
        [id, ...update.map((key) => data[key])]
      )
      if (result.rowCount !== 1) throw new UploadError('unavailable', 403)
    }
    return
  }

  if (op === 'patch' || updateOnly.has(table))
    throw new UploadError('unavailable', 403)
  const columns = ['id', ...keys]
  await client.query(
    `insert into public.${table} (${columns.join(', ')}) values (${columns.map((_, index) => `$${index + 1}`).join(', ')})`,
    [id, ...keys.map((key) => data[key])]
  )
}
