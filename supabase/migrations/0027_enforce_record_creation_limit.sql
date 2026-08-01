------------------------------------------------------------
-- Enforce the free record limit at the database boundary.
--
-- The app-side preflight is only a UX affordance: older clients can skip it
-- and two devices can both see spare capacity before either write reaches
-- Postgres. Lifetime usage lives in a protected quota row rather than a
-- records count, so soft/hard deletions cannot restore allowance and creation
-- remains O(1) as a collection grows.
------------------------------------------------------------

create table if not exists public.record_creation_quotas (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  lifetime_record_count bigint not null default 0
    check (lifetime_record_count >= 0),
  updated_at timestamptz not null default now()
);

-- 0025 populated `created_by` for pre-existing records. Reapply its safe
-- fallback before seeding so every historical row, including tombstones, is
-- charged to the owner of the Collection that held it.
with collection_owners as (
  select distinct on (collection_id)
    collection_id,
    user_id
  from public.collection_members
  where role = 'owner'
  order by collection_id, joined_at asc
)
update public.records r
set created_by = co.user_id
from collection_owners co
where r.created_by is null
  and r.collection_id = co.collection_id;

do $attribution_check$
begin
  if exists (select 1 from public.records where created_by is null) then
    raise exception 'Cannot seed record_creation_quotas: every historical record must have a creator';
  end if;
end
$attribution_check$;

insert into public.record_creation_quotas (user_id, lifetime_record_count)
select created_by, count(*)
from public.records
where created_by is not null
group by created_by
on conflict (user_id) do update
set lifetime_record_count = excluded.lifetime_record_count,
    updated_at = now();

-- Quota rows are implementation state. The trigger below is the only
-- application path permitted to read or mutate them.
alter table public.record_creation_quotas enable row level security;
revoke all on table public.record_creation_quotas from anon, authenticated;

create or replace function public.enforce_record_creation_limit()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_is_premium_account boolean;
  v_has_active_entitlement boolean;
  v_lifetime_record_count bigint;
begin
  if v_user_id is null then
    raise exception 'Authentication is required to create a record'
      using errcode = '42501';
  end if;

  -- `created_by` is immutable attribution. Do not let a collection editor
  -- charge a record against another member's free allowance.
  if tg_op = 'UPDATE' then
    if new.created_by is distinct from old.created_by then
      raise exception 'A record creator cannot be changed'
        using errcode = '42501';
    end if;
    return new;
  end if;

  if new.created_by is not null and new.created_by <> v_user_id then
    raise exception 'The supplied record creator does not match the authenticated user'
      using errcode = 'DW002';
  end if;

  -- This row lock serializes all genuinely-new inserts for one creator.
  -- A concurrent insert waits here until the first transaction has updated
  -- its protected quota row.
  select p.is_premium_account
    into v_is_premium_account
    from public.profiles p
   where p.id = v_user_id
   for update;

  if not found then
    raise exception 'Profile not found for authenticated user'
      using errcode = '42501';
  end if;

  -- PowerSync persists both creates and edits through PostgREST upserts.
  -- A BEFORE INSERT trigger runs before Postgres resolves an ON CONFLICT,
  -- so do not consume quota for a row that will become an update.
  if exists (select 1 from public.records r where r.id = new.id) then
    return new;
  end if;

  new.created_by := v_user_id;

  insert into public.record_creation_quotas (user_id)
  values (v_user_id)
  on conflict (user_id) do nothing;

  select q.lifetime_record_count
    into v_lifetime_record_count
    from public.record_creation_quotas q
   where q.user_id = v_user_id
   for update;

  select exists (
    select 1
      from public.iap_entitlements e
     where e.user_id = v_user_id
       and e.status = 'active'
       and e.revoked_at is null
       and (e.expires_at is null or e.expires_at > now())
  ) into v_has_active_entitlement;

  if not (coalesce(v_is_premium_account, false) or v_has_active_entitlement)
     and v_lifetime_record_count >= 5 then
    raise exception 'Free accounts can create up to 5 records. Subscribe to add more.'
      using errcode = 'DW001';
  end if;

  -- Paid records count toward the lifetime creation total too. If the
  -- subscription later expires, it must not reset a creator's free allowance.
  update public.record_creation_quotas
  set lifetime_record_count = lifetime_record_count + 1,
      updated_at = now()
  where user_id = v_user_id;

  return new;
end;
$$;

drop trigger if exists records_enforce_creation_limit on public.records;
create trigger records_enforce_creation_limit
  before insert or update of created_by on public.records
  for each row execute function public.enforce_record_creation_limit();

-- This function is invoked only by the trigger, never as an RPC.
revoke execute on function public.enforce_record_creation_limit() from public;
