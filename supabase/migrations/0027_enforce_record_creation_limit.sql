------------------------------------------------------------
-- Enforce the free record limit at the database boundary.
--
-- The app-side preflight is only a UX affordance: older clients can skip it
-- and two devices can both see spare capacity before either write reaches
-- Postgres. Locking the creator's profile row makes the entitlement lookup
-- and count serial for every record created by that user.
------------------------------------------------------------

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
  v_created_record_count integer;
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

  -- This row lock is the concurrency guard. A second concurrent INSERT for
  -- the same creator waits here, then performs its count after the first
  -- transaction commits.
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

  select exists (
    select 1
      from public.iap_entitlements e
     where e.user_id = v_user_id
       and e.status = 'active'
       and e.revoked_at is null
       and (e.expires_at is null or e.expires_at > now())
  ) into v_has_active_entitlement;

  if coalesce(v_is_premium_account, false) or v_has_active_entitlement then
    return new;
  end if;

  select count(*)
    into v_created_record_count
    from public.records r
   where r.created_by = v_user_id;

  if v_created_record_count >= 5 then
    raise exception 'Free accounts can create up to 5 records. Subscribe to add more.'
      using errcode = 'P0001';
  end if;

  return new;
end;
$$;

drop trigger if exists records_enforce_creation_limit on public.records;
create trigger records_enforce_creation_limit
  before insert or update of created_by on public.records
  for each row execute function public.enforce_record_creation_limit();

-- This function is invoked only by the trigger, never as an RPC.
revoke execute on function public.enforce_record_creation_limit() from public;
