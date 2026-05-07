-- Collections: shareable containers for owned/wishlist records.
-- A user belongs to one or more collections via collection_members. The Records
-- tab shows the union of records across every collection the user is in. The
-- personal collection (created on signup) doubles as the user's private space —
-- records there are visible only to its members.
--
-- Mirrors the lists / list_members / pending_invites pattern from 0004_lists.sql
-- and 0008_pending_invites.sql.

create type public.collection_member_role as enum ('owner', 'editor', 'viewer');

create table if not exists public.collections (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  created_by uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);

create index if not exists collections_created_by_idx
  on public.collections (created_by) where deleted_at is null;

create table if not exists public.collection_members (
  collection_id uuid not null references public.collections(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  role public.collection_member_role not null default 'editor',
  invited_by uuid references public.profiles(id) on delete set null,
  joined_at timestamptz not null default now(),
  primary key (collection_id, user_id)
);

create index if not exists collection_members_user_idx
  on public.collection_members (user_id);

create table if not exists public.collection_pending_invites (
  id uuid primary key default gen_random_uuid(),
  collection_id uuid not null references public.collections(id) on delete cascade,
  email text not null,
  role public.collection_member_role not null default 'editor',
  invited_by uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  accepted_at timestamptz,
  unique (collection_id, email)
);

create index if not exists collection_pending_invites_email_idx
  on public.collection_pending_invites (lower(email))
  where accepted_at is null;

------------------------------------------------------------
-- profile pointer: which collection should new records default to
------------------------------------------------------------
alter table public.profiles
  add column if not exists primary_collection_id uuid references public.collections(id) on delete set null;

------------------------------------------------------------
-- updated_at trigger
------------------------------------------------------------
drop trigger if exists collections_touch_updated_at on public.collections;
create trigger collections_touch_updated_at
  before update on public.collections
  for each row execute function public.touch_updated_at();

------------------------------------------------------------
-- RLS
------------------------------------------------------------
alter table public.collections enable row level security;
alter table public.collection_members enable row level security;
alter table public.collection_pending_invites enable row level security;

-- A member can read the collection.
drop policy if exists "collections read member" on public.collections;
create policy "collections read member" on public.collections
  for select using (
    deleted_at is null and exists (
      select 1 from public.collection_members m
      where m.collection_id = id and m.user_id = auth.uid()
    )
  );

-- The creator (or any owner-role member) can update / soft-delete the collection.
drop policy if exists "collections write owner" on public.collections;
create policy "collections write owner" on public.collections
  for all using (
    exists (
      select 1 from public.collection_members m
      where m.collection_id = id and m.user_id = auth.uid() and m.role = 'owner'
    )
  ) with check (
    -- Allow the creator to insert their own row before any membership exists.
    created_by = auth.uid()
    or exists (
      select 1 from public.collection_members m
      where m.collection_id = id and m.user_id = auth.uid() and m.role = 'owner'
    )
  );

-- Members can read the membership list of any collection they belong to.
drop policy if exists "collection_members read" on public.collection_members;
create policy "collection_members read" on public.collection_members
  for select using (
    exists (
      select 1 from public.collection_members m2
      where m2.collection_id = collection_id and m2.user_id = auth.uid()
    )
  );

-- Only owner-role members can manage the membership list. A user can also
-- always remove themselves (the leave-collection flow).
drop policy if exists "collection_members write owner" on public.collection_members;
create policy "collection_members write owner" on public.collection_members
  for all using (
    exists (
      select 1 from public.collection_members m
      where m.collection_id = collection_members.collection_id
        and m.user_id = auth.uid() and m.role = 'owner'
    )
    or user_id = auth.uid()
  ) with check (
    exists (
      select 1 from public.collection_members m
      where m.collection_id = collection_members.collection_id
        and m.user_id = auth.uid() and m.role = 'owner'
    )
    or user_id = auth.uid()
  );

-- Pending invites: collection owners read/write; the invitee (once their email
-- matches an authed user) can see their own row.
drop policy if exists "collection_pending_invites owner all" on public.collection_pending_invites;
create policy "collection_pending_invites owner all" on public.collection_pending_invites
  for all using (
    exists (
      select 1 from public.collection_members m
      where m.collection_id = collection_pending_invites.collection_id
        and m.user_id = auth.uid() and m.role = 'owner'
    )
  ) with check (
    exists (
      select 1 from public.collection_members m
      where m.collection_id = collection_pending_invites.collection_id
        and m.user_id = auth.uid() and m.role = 'owner'
    )
  );

drop policy if exists "collection_pending_invites by email" on public.collection_pending_invites;
create policy "collection_pending_invites by email" on public.collection_pending_invites
  for select using (
    lower(email) = lower((select email from auth.users where id = auth.uid()))
  );
