create extension if not exists pgcrypto;

create or replace function public.normalized_artist_sort_name(p_artist text)
returns text
language sql
immutable
as $$
  select regexp_replace(
    regexp_replace(lower(btrim(coalesce(p_artist, ''))), '\s+\([0-9]+\)$', ''),
    '^the\s+',
    ''
  );
$$;

create or replace function public.stable_catalog_uuid(p_key text)
returns uuid
language sql
immutable
as $$
  with h as (
    select encode(digest(p_key, 'sha256'), 'hex') as value
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

create or replace function public.album_dedupe_key(
  p_title text,
  p_artist text,
  p_album_year int
) returns text
language sql
immutable
as $$
  select concat_ws(
    ':',
    'album',
    lower(btrim(coalesce(p_title, ''))),
    public.normalized_artist_sort_name(p_artist),
    coalesce(p_album_year::text, '')
  );
$$;

create or replace function public.record_pressing_dedupe_key(
  p_album_id uuid,
  p_record_year int,
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
      'pressing',
      p_album_id::text,
      lower(btrim(coalesce(p_colourway, ''))),
      coalesce(p_record_year::text, '')
    )
  end;
$$;

create table if not exists public.albums (
  id uuid primary key default gen_random_uuid(),
  dedupe_key text not null unique,
  title text not null,
  artist text not null,
  album_year int,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists albums_artist_title_idx
  on public.albums (artist, title);

drop trigger if exists albums_touch_updated_at on public.albums;
create trigger albums_touch_updated_at
  before update on public.albums
  for each row execute function public.touch_updated_at();

create table if not exists public.record_pressings (
  id uuid primary key default gen_random_uuid(),
  album_id uuid not null references public.albums(id) on delete restrict,
  dedupe_key text not null unique,
  year int,
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

create index if not exists record_pressings_album_idx
  on public.record_pressings (album_id);

create index if not exists record_pressings_discogs_release_idx
  on public.record_pressings (discogs_release_id)
  where discogs_release_id is not null;

create index if not exists record_pressings_barcode_idx
  on public.record_pressings (barcode)
  where barcode is not null;

drop trigger if exists record_pressings_touch_updated_at on public.record_pressings;
create trigger record_pressings_touch_updated_at
  before update on public.record_pressings
  for each row execute function public.touch_updated_at();

alter table public.records
  add column if not exists record_pressing_id uuid references public.record_pressings(id) on delete restrict;

with album_candidates as (
  select
    public.album_dedupe_key(title, artist, album_year) as dedupe_key,
    title,
    regexp_replace(artist, '\s+\([0-9]+\)$', '') as artist,
    album_year,
    created_at,
    updated_at
  from public.records
),
canonical_albums as (
  select distinct on (dedupe_key)
    public.stable_catalog_uuid(dedupe_key) as id,
    *
  from album_candidates
  order by dedupe_key, updated_at desc
)
insert into public.albums (
  id, dedupe_key, title, artist, album_year, created_at, updated_at
)
select id, dedupe_key, title, artist, album_year, created_at, updated_at
from canonical_albums
on conflict (dedupe_key) do nothing;

with pressing_candidates as (
  select
    a.id as album_id,
    public.record_pressing_dedupe_key(
      a.id, r.year, r.colourway, r.discogs_release_id, r.barcode
    ) as dedupe_key,
    r.year,
    r.colourway,
    r.cover_art_source_url,
    r.cover_art_storage_path,
    r.discogs_release_id,
    r.barcode,
    r.estimated_price_cents,
    r.estimated_price_currency,
    r.estimated_price_updated_at,
    r.created_at,
    r.updated_at
  from public.records r
  join public.albums a
    on a.dedupe_key = public.album_dedupe_key(r.title, r.artist, r.album_year)
),
canonical_pressings as (
  select distinct on (dedupe_key)
    public.stable_catalog_uuid(dedupe_key) as id,
    *
  from pressing_candidates
  order by dedupe_key, updated_at desc
)
insert into public.record_pressings (
  id, album_id, dedupe_key, year, colourway,
  cover_art_source_url, cover_art_storage_path,
  discogs_release_id, barcode,
  estimated_price_cents, estimated_price_currency, estimated_price_updated_at,
  created_at, updated_at
)
select
  id, album_id, dedupe_key, year, colourway,
  cover_art_source_url, cover_art_storage_path,
  discogs_release_id, barcode,
  estimated_price_cents, estimated_price_currency, estimated_price_updated_at,
  created_at, updated_at
from canonical_pressings
on conflict (dedupe_key) do nothing;

update public.records r
set record_pressing_id = rp.id
from public.albums a
join public.record_pressings rp on rp.album_id = a.id
where r.record_pressing_id is null
  and a.dedupe_key = public.album_dedupe_key(r.title, r.artist, r.album_year)
  and rp.dedupe_key = public.record_pressing_dedupe_key(
    a.id, r.year, r.colourway, r.discogs_release_id, r.barcode
  );

create index if not exists records_record_pressing_idx
  on public.records (record_pressing_id)
  where deleted_at is null;

alter table public.albums enable row level security;
alter table public.record_pressings enable row level security;

drop policy if exists "albums authenticated read" on public.albums;
create policy "albums authenticated read" on public.albums
  for select using (auth.uid() is not null);

drop policy if exists "albums authenticated insert" on public.albums;
create policy "albums authenticated insert" on public.albums
  for insert with check (auth.uid() is not null);

drop policy if exists "albums authenticated update" on public.albums;
create policy "albums authenticated update" on public.albums
  for update using (auth.uid() is not null) with check (auth.uid() is not null);

drop policy if exists "record pressings authenticated read" on public.record_pressings;
create policy "record pressings authenticated read" on public.record_pressings
  for select using (auth.uid() is not null);

drop policy if exists "record pressings authenticated insert" on public.record_pressings;
create policy "record pressings authenticated insert" on public.record_pressings
  for insert with check (auth.uid() is not null);

drop policy if exists "record pressings authenticated update" on public.record_pressings;
create policy "record pressings authenticated update" on public.record_pressings
  for update using (auth.uid() is not null) with check (auth.uid() is not null);

create or replace function public.get_shared_list_records(token text)
returns table (
  id uuid,
  title text,
  artist text,
  year int,
  colourway text,
  cover_art_storage_path text,
  cover_art_source_url text,
  "position" int
) language sql stable security definer set search_path = public as $$
  select r.id, a.title, a.artist, rp.year, rp.colourway,
         rp.cover_art_storage_path, rp.cover_art_source_url, li.position
  from public.lists l
  join public.list_items li on li.list_id = l.id
  join public.records r on r.id = li.record_id
  join public.record_pressings rp on rp.id = r.record_pressing_id
  join public.albums a on a.id = rp.album_id
  where l.share_token = token
    and l.share_mode = 'link_public'
    and l.deleted_at is null
    and r.deleted_at is null
  order by li.position asc, li.created_at asc;
$$;

grant execute on function public.get_shared_list_records(text) to anon, authenticated;

drop index if exists public.records_barcode_idx;

alter table public.records
  drop column if exists title,
  drop column if exists artist,
  drop column if exists year,
  drop column if exists album_year,
  drop column if exists colourway,
  drop column if exists cover_art_source_url,
  drop column if exists cover_art_storage_path,
  drop column if exists discogs_release_id,
  drop column if exists barcode,
  drop column if exists estimated_price_cents,
  drop column if exists estimated_price_currency,
  drop column if exists estimated_price_updated_at;

drop publication if exists powersync;

create publication powersync for table
  public.profiles,
  public.records,
  public.albums,
  public.record_pressings,
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
