-- Normalize release-level facts away from collection-scoped records.
--
-- `records` remains the per-Collection owned/wishlist row used by lists,
-- prices, notifications, and deep links. `record_releases` becomes the
-- canonical release/value row shared by those collection entries.

create extension if not exists pgcrypto;

create or replace function public.record_release_dedupe_key(
  p_title text,
  p_artist text,
  p_album_year int,
  p_year int,
  p_colourway text,
  p_discogs_release_id bigint,
  p_barcode text
) returns text
language sql
immutable
as $$
  select case
    when p_discogs_release_id is not null then 'discogs:' || p_discogs_release_id::text
    when nullif(btrim(coalesce(p_barcode, '')), '') is not null then 'barcode:' || lower(btrim(p_barcode))
    else concat_ws(
      ':',
      'manual',
      lower(btrim(coalesce(p_title, ''))),
      regexp_replace(
        regexp_replace(lower(btrim(coalesce(p_artist, ''))), '\s+\([0-9]+\)$', ''),
        '^the\s+',
        ''
      ),
      lower(btrim(coalesce(p_colourway, ''))),
      coalesce(coalesce(p_album_year, p_year)::text, '')
    )
  end;
$$;

create or replace function public.record_release_uuid(p_dedupe_key text)
returns uuid
language sql
immutable
as $$
  with h as (
    select encode(digest(p_dedupe_key, 'sha256'), 'hex') as value
  )
  select (
    substr(value, 1, 8) || '-' ||
    substr(value, 9, 4) || '-' ||
    '5' || substr(value, 14, 3) || '-' ||
    '8' || substr(value, 18, 3) || '-' ||
    substr(value, 21, 12)
  )::uuid
  from h;
$$;

create table if not exists public.record_releases (
  id uuid primary key default gen_random_uuid(),
  dedupe_key text not null unique,
  title text not null,
  artist text not null,
  year int,
  album_year int,
  colourway text,
  cover_art_source_url text,
  cover_art_storage_path text,
  discogs_release_id bigint,
  barcode text,
  estimated_price_cents int,
  estimated_price_currency text,
  estimated_price_updated_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists record_releases_discogs_release_idx
  on public.record_releases (discogs_release_id)
  where discogs_release_id is not null;

create index if not exists record_releases_barcode_idx
  on public.record_releases (barcode)
  where barcode is not null;

drop trigger if exists record_releases_touch_updated_at on public.record_releases;
create trigger record_releases_touch_updated_at
  before update on public.record_releases
  for each row execute function public.touch_updated_at();

alter table public.records
  add column if not exists record_release_id uuid references public.record_releases(id) on delete restrict;

with candidates as (
  select
    public.record_release_dedupe_key(
      title, artist, album_year, year, colourway, discogs_release_id, barcode
    ) as dedupe_key,
    title,
    artist,
    year,
    album_year,
    colourway,
    cover_art_source_url,
    cover_art_storage_path,
    discogs_release_id,
    barcode,
    estimated_price_cents,
    estimated_price_currency,
    estimated_price_updated_at,
    created_at,
    updated_at
  from public.records
  where deleted_at is null
),
canonical as (
  select distinct on (dedupe_key)
    public.record_release_uuid(dedupe_key) as id,
    *
  from candidates
  order by dedupe_key, updated_at desc
)
insert into public.record_releases (
  id, dedupe_key, title, artist, year, album_year, colourway,
  cover_art_source_url, cover_art_storage_path,
  discogs_release_id, barcode,
  estimated_price_cents, estimated_price_currency, estimated_price_updated_at,
  created_at, updated_at
)
select
  id, dedupe_key, title, artist, year, album_year, colourway,
  cover_art_source_url, cover_art_storage_path,
  discogs_release_id, barcode,
  estimated_price_cents, estimated_price_currency, estimated_price_updated_at,
  created_at, updated_at
from canonical
on conflict (dedupe_key) do nothing;

update public.records r
set record_release_id = rr.id
from public.record_releases rr
where r.record_release_id is null
  and rr.dedupe_key = public.record_release_dedupe_key(
    r.title, r.artist, r.album_year, r.year, r.colourway, r.discogs_release_id, r.barcode
  );

create index if not exists records_record_release_idx
  on public.records (record_release_id)
  where deleted_at is null;

alter table public.record_releases enable row level security;

drop policy if exists "record releases authenticated read" on public.record_releases;
create policy "record releases authenticated read" on public.record_releases
  for select using (auth.uid() is not null);

drop policy if exists "record releases authenticated insert" on public.record_releases;
create policy "record releases authenticated insert" on public.record_releases
  for insert with check (auth.uid() is not null);

drop policy if exists "record releases authenticated update" on public.record_releases;
create policy "record releases authenticated update" on public.record_releases
  for update using (auth.uid() is not null) with check (auth.uid() is not null);

-- Refresh PowerSync publication to include the new canonical table.
drop publication if exists powersync;

create publication powersync for table
  public.profiles,
  public.records,
  public.record_releases,
  public.price_entries,
  public.lists,
  public.list_items,
  public.list_members,
  public.pending_invites,
  public.device_tokens,
  public.collections,
  public.collection_members,
  public.collection_pending_invites,
  public.notifications,
  public.record_images;
