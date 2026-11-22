-- Shareable lists with three sharing modes:
--   private:        only the owner can read/write
--   link_public:    anyone with the share token can read (no auth required)
--   invite:         only members can read; only editors can write
--   collaborative:  members can read and write (multi-user editing)

create type list_share_mode as enum ('private', 'link_public', 'invite', 'collaborative');
create type list_member_role as enum ('viewer', 'editor');

create table if not exists public.lists (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profiles(id) on delete cascade,
  name text not null,
  description text,
  share_mode list_share_mode not null default 'private',
  share_token text unique,                         -- present iff share_mode = 'link_public'
  cover_record_id uuid references public.records(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);

create index if not exists lists_owner_idx on public.lists (owner_id) where deleted_at is null;

create table if not exists public.list_items (
  id uuid primary key default gen_random_uuid(),
  list_id uuid not null references public.lists(id) on delete cascade,
  record_id uuid not null references public.records(id) on delete cascade,
  added_by uuid not null references public.profiles(id) on delete cascade,
  position int not null default 0,
  created_at timestamptz not null default now(),
  unique (list_id, record_id)
);

create index if not exists list_items_list_idx on public.list_items (list_id, position);

create table if not exists public.list_members (
  list_id uuid not null references public.lists(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  role list_member_role not null default 'viewer',
  invited_by uuid references public.profiles(id) on delete set null,
  joined_at timestamptz not null default now(),
  primary key (list_id, user_id)
);

create index if not exists list_members_user_idx on public.list_members (user_id);

------------------------------------------------------------
-- updated_at trigger
------------------------------------------------------------
drop trigger if exists lists_touch_updated_at on public.lists;
create trigger lists_touch_updated_at
  before update on public.lists
  for each row execute function public.touch_updated_at();

------------------------------------------------------------
-- helper: can the current auth.uid() read a given list?
------------------------------------------------------------
create or replace function public.can_read_list(list public.lists)
returns boolean language sql stable security definer set search_path = public as $$
  select
    list.deleted_at is null and (
      list.owner_id = auth.uid()
      or list.share_mode = 'link_public'
      or exists (
        select 1 from public.list_members m
        where m.list_id = list.id and m.user_id = auth.uid()
      )
    );
$$;

create or replace function public.can_write_list(list public.lists)
returns boolean language sql stable security definer set search_path = public as $$
  select
    list.deleted_at is null and (
      list.owner_id = auth.uid()
      or (
        list.share_mode in ('invite', 'collaborative')
        and exists (
          select 1 from public.list_members m
          where m.list_id = list.id
            and m.user_id = auth.uid()
            and (m.role = 'editor' or list.share_mode = 'collaborative')
        )
      )
    );
$$;

------------------------------------------------------------
-- RLS
------------------------------------------------------------
alter table public.lists enable row level security;
alter table public.list_items enable row level security;
alter table public.list_members enable row level security;

drop policy if exists "lists read" on public.lists;
create policy "lists read" on public.lists
  for select using (public.can_read_list(lists));

drop policy if exists "lists write owner" on public.lists;
create policy "lists write owner" on public.lists
  for all using (owner_id = auth.uid()) with check (owner_id = auth.uid());

drop policy if exists "list_items read" on public.list_items;
create policy "list_items read" on public.list_items
  for select using (
    exists (select 1 from public.lists l
            where l.id = list_id and public.can_read_list(l))
  );

drop policy if exists "list_items write" on public.list_items;
create policy "list_items write" on public.list_items
  for all using (
    exists (select 1 from public.lists l
            where l.id = list_id and public.can_write_list(l))
  ) with check (
    exists (select 1 from public.lists l
            where l.id = list_id and public.can_write_list(l))
  );

drop policy if exists "list_members read" on public.list_members;
create policy "list_members read" on public.list_members
  for select using (
    exists (select 1 from public.lists l
            where l.id = list_id and public.can_read_list(l))
  );

drop policy if exists "list_members write owner" on public.list_members;
create policy "list_members write owner" on public.list_members
  for all using (
    exists (select 1 from public.lists l
            where l.id = list_id and l.owner_id = auth.uid())
  ) with check (
    exists (select 1 from public.lists l
            where l.id = list_id and l.owner_id = auth.uid())
  );

------------------------------------------------------------
-- public read RPCs for link_public lists (no auth required)
------------------------------------------------------------
create or replace function public.get_shared_list(token text)
returns table (
  id uuid,
  name text,
  description text,
  owner_display_name text,
  cover_record_id uuid,
  updated_at timestamptz
) language sql stable security definer set search_path = public as $$
  select l.id, l.name, l.description, p.display_name, l.cover_record_id, l.updated_at
  from public.lists l
  left join public.profiles p on p.id = l.owner_id
  where l.share_token = token and l.share_mode = 'link_public' and l.deleted_at is null;
$$;

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
  select r.id, r.title, r.artist, r.year, r.colourway,
         r.cover_art_storage_path, r.cover_art_source_url, li.position
  from public.lists l
  join public.list_items li on li.list_id = l.id
  join public.records r on r.id = li.record_id
  where l.share_token = token
    and l.share_mode = 'link_public'
    and l.deleted_at is null
    and r.deleted_at is null
  order by li.position asc, li.created_at asc;
$$;

grant execute on function public.get_shared_list(text) to anon, authenticated;
grant execute on function public.get_shared_list_records(text) to anon, authenticated;
