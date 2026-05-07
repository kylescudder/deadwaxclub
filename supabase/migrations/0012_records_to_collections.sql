-- Re-parent records and price_entries from a single owner_id onto collection_id.
-- For every existing profile we mint a personal Collection, add the profile as
-- the 'owner' member, set it as their primary_collection_id, and rewrite all
-- their records / price_entries onto that collection.

------------------------------------------------------------
-- 1. Add nullable collection_id columns.
------------------------------------------------------------
alter table public.records
  add column if not exists collection_id uuid references public.collections(id) on delete cascade;

alter table public.price_entries
  add column if not exists collection_id uuid references public.collections(id) on delete cascade;

------------------------------------------------------------
-- 2. Backfill: one personal Collection per profile.
------------------------------------------------------------
do $backfill$
declare
  prof record;
  new_coll_id uuid;
  coll_name text;
begin
  for prof in select id, display_name from public.profiles loop
    -- Skip if this profile already has a primary collection (idempotency).
    if (select primary_collection_id from public.profiles where id = prof.id) is not null then
      continue;
    end if;

    coll_name := coalesce(prof.display_name || '''s Collection', 'My Collection');

    insert into public.collections (name, created_by)
    values (coll_name, prof.id)
    returning id into new_coll_id;

    insert into public.collection_members (collection_id, user_id, role, invited_by)
    values (new_coll_id, prof.id, 'owner', prof.id);

    update public.profiles
    set primary_collection_id = new_coll_id
    where id = prof.id;

    update public.records
    set collection_id = new_coll_id
    where owner_id = prof.id and collection_id is null;

    update public.price_entries
    set collection_id = new_coll_id
    where owner_id = prof.id and collection_id is null;
  end loop;
end
$backfill$;

------------------------------------------------------------
-- 3. Lock collection_id NOT NULL once backfill is complete.
------------------------------------------------------------
alter table public.records alter column collection_id set not null;
alter table public.price_entries alter column collection_id set not null;

------------------------------------------------------------
-- 4. Replace owner-keyed indexes with collection-keyed ones.
------------------------------------------------------------
drop index if exists public.records_owner_status_idx;
drop index if exists public.records_barcode_idx;

create index if not exists records_collection_status_idx
  on public.records (collection_id, status)
  where deleted_at is null;

create index if not exists records_barcode_idx
  on public.records (collection_id, barcode)
  where deleted_at is null and barcode is not null;

create index if not exists price_entries_collection_idx
  on public.price_entries (collection_id, scanned_at desc);

------------------------------------------------------------
-- 5. Replace RLS — visibility is now collection membership.
--    Done before dropping owner_id because the old policy references it.
------------------------------------------------------------
drop policy if exists "records owner all" on public.records;
create policy "records member rw" on public.records
  for all using (
    exists (
      select 1 from public.collection_members m
      where m.collection_id = records.collection_id and m.user_id = auth.uid()
    )
  ) with check (
    exists (
      select 1 from public.collection_members m
      where m.collection_id = records.collection_id
        and m.user_id = auth.uid()
        and m.role in ('owner', 'editor')
    )
  );

drop policy if exists "price_entries owner all" on public.price_entries;
create policy "price_entries member rw" on public.price_entries
  for all using (
    exists (
      select 1 from public.collection_members m
      where m.collection_id = price_entries.collection_id and m.user_id = auth.uid()
    )
  ) with check (
    exists (
      select 1 from public.collection_members m
      where m.collection_id = price_entries.collection_id
        and m.user_id = auth.uid()
        and m.role in ('owner', 'editor')
    )
  );

------------------------------------------------------------
-- 6. Drop the now-unused owner_id from records.
--    price_entries.owner_id is kept as audit ("who logged this price").
------------------------------------------------------------
alter table public.records drop column if exists owner_id;
