------------------------------------------------------------
-- Enforce the free record limit at the database boundary.
--
-- The app-side preflight is only a UX affordance: older clients can skip it
-- and two devices can both see spare capacity before either write reaches
-- Postgres. Lifetime usage lives in a protected quota row rather than a
-- records count, so soft/hard deletions cannot restore allowance and creation
-- remains O(1) as a collection grows.
------------------------------------------------------------

-- Supabase applies each migration in one transaction. This lock therefore
-- covers historical attribution, quota seeding, and trigger installation: an
-- INSERT/UPDATE/DELETE cannot slip between the seed snapshot and enforcement.
lock table public.records in share row exclusive mode;

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

-- A row written by the former decoded-payload implementation deliberately
-- remains unverified: these nullable columns are not backfilled. Only the
-- service-role writer below can turn a newly Apple-verified transaction into
-- an entitlement that the creation trigger accepts.
alter table public.iap_entitlements
  add column if not exists bundle_id text,
  add column if not exists transaction_id text,
  add column if not exists signed_at timestamptz,
  add column if not exists verified_at timestamptz,
  add column if not exists verification_source text;

create unique index if not exists iap_entitlements_transaction_id_idx
  on public.iap_entitlements (transaction_id)
  where transaction_id is not null;

-- Deadwax's cross-boundary entitlement contract. The Edge Functions use the
-- same bundle, product, environments, and source values before calling this
-- service-role-only function. Keep this list deliberately exact: accepting
-- any active product would turn an unrelated purchase into an unlimited plan.
create or replace function public.apply_verified_iap_entitlement(
  p_user_id uuid,
  p_bundle_id text,
  p_product_id text,
  p_transaction_id text,
  p_original_transaction_id text,
  p_status text,
  p_expires_at timestamptz,
  p_revoked_at timestamptz,
  p_environment text,
  p_signed_at timestamptz,
  p_verified_at timestamptz,
  p_verification_source text
)
returns public.iap_entitlements
language plpgsql
security definer
set search_path = public
as $$
declare
  v_entitlement public.iap_entitlements;
begin
  if auth.role() <> 'service_role' then
    raise exception 'Only the entitlement verification service may write entitlements'
      using errcode = '42501';
  end if;

  if p_user_id is null
     or p_bundle_id <> 'com.deadwaxclub.app'
     or p_product_id <> 'club.deadwax.supporter.monthly'
     or p_environment not in ('sandbox', 'production')
     or p_verification_source not in ('storekit_transaction', 'app_store_server_notification')
     or p_status not in ('active', 'expired', 'revoked')
     or nullif(trim(p_transaction_id), '') is null
     or nullif(trim(p_original_transaction_id), '') is null
     or p_signed_at is null
     or p_verified_at is null
     or p_verified_at < p_signed_at
     -- The accepted product is an auto-renewing monthly subscription. Both
     -- active and expired events must carry Apple's expiry timestamp.
     or (p_status in ('active', 'expired') and p_expires_at is null)
     or (p_status = 'active' and p_revoked_at is not null) then
    raise exception 'Rejected verified entitlement payload'
      using errcode = 'DW003';
  end if;

  insert into public.iap_entitlements (
    user_id, bundle_id, product_id, transaction_id, original_transaction_id,
    status, expires_at, revoked_at, environment, signed_at, verified_at,
    verification_source, updated_at
  ) values (
    p_user_id, p_bundle_id, p_product_id, p_transaction_id,
    p_original_transaction_id, p_status, p_expires_at, p_revoked_at,
    p_environment, p_signed_at, p_verified_at, p_verification_source, now()
  )
  on conflict (user_id) do update
  set bundle_id = excluded.bundle_id,
      product_id = excluded.product_id,
      transaction_id = excluded.transaction_id,
      original_transaction_id = excluded.original_transaction_id,
      status = excluded.status,
      expires_at = excluded.expires_at,
      revoked_at = excluded.revoked_at,
      environment = excluded.environment,
      signed_at = excluded.signed_at,
      verified_at = excluded.verified_at,
      verification_source = excluded.verification_source,
      updated_at = now()
  -- Apple signed time, rather than receipt/verification time, establishes
  -- entitlement ordering. A delayed old active event must not undo a newer
  -- revoke or expiry event.
  where public.iap_entitlements.signed_at is null
     or excluded.signed_at >= public.iap_entitlements.signed_at
  returning * into v_entitlement;

  -- A delayed event is intentionally ignored. Return the current authoritative
  -- row so the Edge Function response cannot promise a stale entitlement.
  if not found then
    select * into v_entitlement
    from public.iap_entitlements
    where user_id = p_user_id;
  end if;
  return v_entitlement;
end;
$$;

revoke all on function public.apply_verified_iap_entitlement(
  uuid, text, text, text, text, text, timestamptz, timestamptz, text,
  timestamptz, timestamptz, text
) from public, anon, authenticated;
grant execute on function public.apply_verified_iap_entitlement(
  uuid, text, text, text, text, text, timestamptz, timestamptz, text,
  timestamptz, timestamptz, text
) to service_role;

create or replace function public.has_verified_deadwax_entitlement(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.iap_entitlements e
    where e.user_id = p_user_id
      and e.bundle_id = 'com.deadwaxclub.app'
      and e.product_id = 'club.deadwax.supporter.monthly'
      and e.environment in ('sandbox', 'production')
      and e.signed_at is not null
      and e.verified_at is not null
      and e.verification_source in (
        'storekit_transaction',
        'app_store_server_notification'
      )
      and e.status = 'active'
      and e.revoked_at is null
      and e.expires_at is not null
      and e.expires_at > now()
  );
$$;

revoke execute on function public.has_verified_deadwax_entitlement(uuid) from public;

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

  select public.has_verified_deadwax_entitlement(v_user_id)
    into v_has_active_entitlement;

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
