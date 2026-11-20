-- Fix the infinite-recursion error PostgreSQL reports against
-- `collection_members`'s RLS policies.
--
-- Original mistake: every policy that had to ask "is the user a member of
-- this collection?" inlined the lookup as `exists (select … from
-- collection_members …)`. Because that subquery is evaluated under RLS, and
-- collection_members's own policy did the *same* lookup, Postgres hit
-- infinite recursion the moment you tried to read or write any row whose
-- visibility derived from collection membership (which is — by design —
-- almost every row in this schema).
--
-- Fix: wrap the membership / role checks in `security definer` functions
-- that run with the function-owner's privileges and skip RLS. Then point
-- every policy at the helper instead of inlining the subquery.

------------------------------------------------------------
-- Helper functions
------------------------------------------------------------
create or replace function public.is_collection_member(p_collection_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.collection_members
    where collection_id = p_collection_id and user_id = auth.uid()
  );
$$;

create or replace function public.is_collection_writer(p_collection_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.collection_members
    where collection_id = p_collection_id
      and user_id = auth.uid()
      and role in ('owner', 'editor')
  );
$$;

create or replace function public.is_collection_owner(p_collection_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.collection_members
    where collection_id = p_collection_id
      and user_id = auth.uid()
      and role = 'owner'
  );
$$;

grant execute on function public.is_collection_member(uuid) to authenticated;
grant execute on function public.is_collection_writer(uuid) to authenticated;
grant execute on function public.is_collection_owner(uuid)  to authenticated;

------------------------------------------------------------
-- collections
------------------------------------------------------------
drop policy if exists "collections read member" on public.collections;
create policy "collections read member" on public.collections
  for select using (
    deleted_at is null and public.is_collection_member(id)
  );

drop policy if exists "collections write owner" on public.collections;
create policy "collections write owner" on public.collections
  for all using (
    public.is_collection_owner(id)
  ) with check (
    -- The creator's first INSERT runs before any membership row exists, so
    -- allow it; subsequent updates require an owner-role membership.
    created_by = auth.uid() or public.is_collection_owner(id)
  );

------------------------------------------------------------
-- collection_members (the recursive offender)
------------------------------------------------------------
drop policy if exists "collection_members read" on public.collection_members;
create policy "collection_members read" on public.collection_members
  for select using (
    public.is_collection_member(collection_id)
  );

drop policy if exists "collection_members write owner" on public.collection_members;
create policy "collection_members write owner" on public.collection_members
  for all using (
    public.is_collection_owner(collection_id) or user_id = auth.uid()
  ) with check (
    public.is_collection_owner(collection_id) or user_id = auth.uid()
  );

------------------------------------------------------------
-- collection_pending_invites
------------------------------------------------------------
drop policy if exists "collection_pending_invites owner all" on public.collection_pending_invites;
create policy "collection_pending_invites owner all" on public.collection_pending_invites
  for all using (
    public.is_collection_owner(collection_id)
  ) with check (
    public.is_collection_owner(collection_id)
  );

-- Invitee-by-email policy stays as-is — it doesn't reference collection_members.

------------------------------------------------------------
-- records
------------------------------------------------------------
drop policy if exists "records member rw" on public.records;
create policy "records member rw" on public.records
  for all using (
    public.is_collection_member(collection_id)
  ) with check (
    public.is_collection_writer(collection_id)
  );

------------------------------------------------------------
-- price_entries
------------------------------------------------------------
drop policy if exists "price_entries member rw" on public.price_entries;
create policy "price_entries member rw" on public.price_entries
  for all using (
    public.is_collection_member(collection_id)
  ) with check (
    public.is_collection_writer(collection_id)
  );

------------------------------------------------------------
-- record_images
------------------------------------------------------------
drop policy if exists "record_images member rw" on public.record_images;
create policy "record_images member rw" on public.record_images
  for all using (
    public.is_collection_member(collection_id)
  ) with check (
    public.is_collection_writer(collection_id)
  );
