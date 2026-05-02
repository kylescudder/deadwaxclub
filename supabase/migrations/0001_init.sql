-- DeadWaxClub initial schema.
-- Run via: supabase db push  (CLI)  or paste into the SQL editor.

create extension if not exists pgcrypto;

------------------------------------------------------------
-- profiles
------------------------------------------------------------
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

------------------------------------------------------------
-- records
------------------------------------------------------------
create table if not exists public.records (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profiles(id) on delete cascade,
  status text not null check (status in ('owned', 'wishlist')),
  title text not null,
  artist text not null,
  year int,
  colourway text,
  cover_art_source_url text,         -- original Discogs URL
  cover_art_storage_path text,       -- path inside `covers` bucket once cached
  discogs_release_id bigint,
  barcode text,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);

create index if not exists records_owner_status_idx
  on public.records (owner_id, status)
  where deleted_at is null;

create index if not exists records_barcode_idx
  on public.records (owner_id, barcode)
  where deleted_at is null and barcode is not null;

------------------------------------------------------------
-- price_entries
------------------------------------------------------------
create table if not exists public.price_entries (
  id uuid primary key default gen_random_uuid(),
  record_id uuid not null references public.records(id) on delete cascade,
  owner_id uuid not null references public.profiles(id) on delete cascade,
  price_cents int not null check (price_cents >= 0),
  currency text not null default 'GBP' check (length(currency) = 3),
  shop_name text,
  scanned_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);

create index if not exists price_entries_record_idx
  on public.price_entries (record_id, scanned_at desc);

------------------------------------------------------------
-- updated_at trigger
------------------------------------------------------------
create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists profiles_touch_updated_at on public.profiles;
create trigger profiles_touch_updated_at
  before update on public.profiles
  for each row execute function public.touch_updated_at();

drop trigger if exists records_touch_updated_at on public.records;
create trigger records_touch_updated_at
  before update on public.records
  for each row execute function public.touch_updated_at();

------------------------------------------------------------
-- auto-create profile on signup
------------------------------------------------------------
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, display_name)
  values (new.id, coalesce(new.raw_user_meta_data->>'display_name', split_part(new.email, '@', 1)))
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

------------------------------------------------------------
-- Row Level Security
------------------------------------------------------------
alter table public.profiles enable row level security;
alter table public.records enable row level security;
alter table public.price_entries enable row level security;

drop policy if exists "profiles read own" on public.profiles;
create policy "profiles read own" on public.profiles
  for select using (id = auth.uid());

drop policy if exists "profiles update own" on public.profiles;
create policy "profiles update own" on public.profiles
  for update using (id = auth.uid()) with check (id = auth.uid());

drop policy if exists "records owner all" on public.records;
create policy "records owner all" on public.records
  for all using (owner_id = auth.uid()) with check (owner_id = auth.uid());

drop policy if exists "price_entries owner all" on public.price_entries;
create policy "price_entries owner all" on public.price_entries
  for all using (owner_id = auth.uid()) with check (owner_id = auth.uid());
