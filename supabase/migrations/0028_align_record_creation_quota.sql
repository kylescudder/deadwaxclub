-- Durable, idempotent lifetime record accounting and initialized PowerSync
-- quota snapshots. This supersedes 0027's row-existence upsert workaround.
begin;

lock table public.records in share row exclusive mode;

create table if not exists public.record_creation_events (
  record_id uuid primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now()
);
create index if not exists record_creation_events_user_id_idx
  on public.record_creation_events (user_id);
create index if not exists records_created_by_updated_at_idx
  on public.records (created_by, updated_at desc);
alter table public.record_creation_events enable row level security;
alter table public.record_creation_events force row level security;
revoke all on table public.record_creation_events from anon, authenticated;

-- Install the initializer before reading profiles for the backfill. A signup
-- racing this migration is therefore covered either by the snapshot below or
-- by this trigger, with ON CONFLICT making the overlap harmless.
create or replace function public.initialize_record_creation_quota()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.record_creation_quotas (user_id, lifetime_record_count, updated_at)
  values (new.id, 0, statement_timestamp()) on conflict (user_id) do nothing;
  return new;
end;
$$;
revoke all on function public.initialize_record_creation_quota() from public;
drop trigger if exists profiles_initialize_record_creation_quota on public.profiles;
create trigger profiles_initialize_record_creation_quota
  after insert on public.profiles for each row
  execute function public.initialize_record_creation_quota();

insert into public.record_creation_events (record_id, user_id, created_at)
select id, created_by, created_at from public.records
where created_by is not null
on conflict (record_id) do nothing;

-- Every profile, including a true zero-use account, gets a row. Existing
-- monotonic counts are never reduced.
insert into public.record_creation_quotas (user_id, lifetime_record_count, updated_at)
select p.id, count(e.record_id), statement_timestamp()
from public.profiles p
left join public.record_creation_events e on e.user_id = p.id
group by p.id
on conflict (user_id) do update
set lifetime_record_count = greatest(
      public.record_creation_quotas.lifetime_record_count,
      excluded.lifetime_record_count
    ),
    updated_at = statement_timestamp();

create or replace function public.get_record_creation_status()
returns table (lifetime_record_count bigint, free_limit integer, has_verified_entitlement boolean)
language plpgsql stable security definer set search_path = public as $$
declare v_user_id uuid := auth.uid();
begin
  if v_user_id is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;
  return query
  select q.lifetime_record_count, 5,
         coalesce(p.is_premium_account, false) or public.has_verified_deadwax_entitlement(v_user_id)
  from public.profiles p
  join public.record_creation_quotas q on q.user_id = p.id
  where p.id = v_user_id;
end;
$$;
revoke all on function public.get_record_creation_status() from public;
grant execute on function public.get_record_creation_status() to authenticated;

create or replace function public.enforce_record_creation_limit()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_user_id uuid := auth.uid();
  v_count bigint;
  v_premium boolean;
begin
  if v_user_id is null then
    raise exception 'Authentication is required to create a record' using errcode = '42501';
  end if;
  if new.created_by is not null and new.created_by <> v_user_id then
    raise exception 'Record creator does not match authenticated user' using errcode = 'DW002';
  end if;
  select is_premium_account into v_premium from public.profiles
  where id = v_user_id for update;
  if not found then
    raise exception 'Profile not found' using errcode = '42501';
  end if;
  new.created_by := v_user_id;

  -- Compatibility for deployed clients that still PUT with PostgREST upsert:
  -- BEFORE INSERT runs before ON CONFLICT, so an already-committed record must
  -- bypass the insert-only ledger path. A hard-deleted ID remains absent and
  -- is still rejected by the durable ledger's primary key below.
  if exists (select 1 from public.records where id = new.id) then
    return new;
  end if;

  -- The ledger makes retries and hard-delete/reinsert cycles unambiguous.
  insert into public.record_creation_events (record_id, user_id)
  values (new.id, v_user_id);
  insert into public.record_creation_quotas (user_id, lifetime_record_count, updated_at)
  values (v_user_id, 1, statement_timestamp())
  on conflict (user_id) do update
  set lifetime_record_count = public.record_creation_quotas.lifetime_record_count + 1,
      updated_at = statement_timestamp()
  returning lifetime_record_count into v_count;

  if v_count > 5 and not (
    coalesce(v_premium, false) or public.has_verified_deadwax_entitlement(v_user_id)
  ) then
    raise exception 'Free record lifetime limit reached' using errcode = 'DW001';
  end if;
  return new;
end;
$$;
revoke all on function public.enforce_record_creation_limit() from public;

create or replace function public.prevent_record_creator_change()
returns trigger language plpgsql set search_path = public as $$
begin
  if new.created_by is distinct from old.created_by then
    raise exception 'Record creator cannot be changed' using errcode = 'DW002';
  end if;
  return new;
end;
$$;
revoke all on function public.prevent_record_creator_change() from public;

drop trigger if exists records_enforce_creation_limit on public.records;
create trigger records_enforce_creation_limit before insert on public.records
for each row execute function public.enforce_record_creation_limit();
drop trigger if exists records_prevent_creator_change on public.records;
create trigger records_prevent_creator_change before update of created_by on public.records
for each row execute function public.prevent_record_creator_change();

-- Add the new snapshot without rebuilding the publication. Device tokens are
-- direct APNs infrastructure and no longer belong in PowerSync replication.
do $$ begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'powersync' and schemaname = 'public'
      and tablename = 'record_creation_quotas'
  ) then
    alter publication powersync add table public.record_creation_quotas;
  end if;
  if exists (
    select 1 from pg_publication_tables
    where pubname = 'powersync' and schemaname = 'public'
      and tablename = 'device_tokens'
  ) then
    alter publication powersync drop table public.device_tokens;
  end if;
end $$;

commit;
