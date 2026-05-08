-- Multiple images per record: a swipable carousel in the iOS app, with the
-- primary image (position 0) staying as `records.cover_art_storage_path` for
-- backwards-compat with the existing cover-art display path used by Spotlight,
-- the Records list, etc.
--
-- `collection_id` is denormalised here so PowerSync's edition-3 sync rules can
-- gate visibility with a single-level subquery (same shape as `member_records`
-- and `member_prices`).

create type public.record_image_kind as enum ('discogs', 'user_upload');

create table public.record_images (
  id uuid primary key default gen_random_uuid(),
  record_id uuid not null references public.records(id) on delete cascade,
  collection_id uuid not null references public.collections(id) on delete cascade,
  kind public.record_image_kind not null,
  position int not null default 0,
  source_url text,                 -- original Discogs URL; null for user uploads
  storage_path text,               -- path in `covers` bucket once uploaded
  uploaded_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);

create index record_images_record_idx
  on public.record_images (record_id, position);

create index record_images_collection_idx
  on public.record_images (collection_id);

------------------------------------------------------------
-- RLS — visibility follows the parent record's collection membership.
------------------------------------------------------------
alter table public.record_images enable row level security;

drop policy if exists "record_images member rw" on public.record_images;
create policy "record_images member rw" on public.record_images
  for all using (
    exists (
      select 1 from public.collection_members m
      where m.collection_id = record_images.collection_id and m.user_id = auth.uid()
    )
  ) with check (
    exists (
      select 1 from public.collection_members m
      where m.collection_id = record_images.collection_id
        and m.user_id = auth.uid()
        and m.role in ('owner', 'editor')
    )
  );

------------------------------------------------------------
-- Add to PowerSync publication so the table replicates.
------------------------------------------------------------
drop publication if exists powersync;

create publication powersync for table
  public.profiles,
  public.records,
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
