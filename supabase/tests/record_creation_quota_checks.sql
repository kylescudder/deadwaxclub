-- Reproducible checks for the authoritative record creation quota migrations.
--
-- Run against a disposable, migrated Supabase database as the database owner:
--   psql "$DATABASE_URL" -f supabase/tests/record_creation_quota_checks.sql
--
-- The script rolls back. It needs one existing profile with a primary
-- Collection; create a normal test account first if the database is empty.

begin;

do $checks$
declare
  v_user_id uuid;
  v_other_user_id uuid;
  v_collection_id uuid;
  v_album_id uuid := gen_random_uuid();
  v_pressing_id uuid := gen_random_uuid();
  v_record_ids uuid[] := array[]::uuid[];
  v_record_id uuid;
  v_count bigint;
  v_failed boolean;
  v_signed_at timestamptz := now() - interval '10 minutes';
  v_status text;
  v_transaction_id text;
begin
  select id, primary_collection_id
    into v_user_id, v_collection_id
    from public.profiles
   where primary_collection_id is not null
   limit 1;
  if v_user_id is null then
    raise exception 'Create a normal Supabase test account before running these checks';
  end if;

  select id into v_other_user_id
  from public.profiles
  where id <> v_user_id
  limit 1;
  if v_other_user_id is null then
    raise exception 'Create a second normal Supabase test account before running these checks';
  end if;

  -- Establish a fresh free account state while this enclosing transaction
  -- keeps production/test fixture data unchanged after ROLLBACK.
  update public.profiles set is_premium_account = false where id = v_user_id;
  delete from public.iap_entitlements where user_id = v_user_id;
  delete from public.record_creation_quotas where user_id = v_user_id;
  perform set_config('request.jwt.claim.sub', v_user_id::text, true);
  perform set_config('request.jwt.claim.role', 'service_role', true);

  insert into public.albums (id, dedupe_key, title, artist)
  values (v_album_id, 'quota-check:' || v_album_id, 'Quota Check', 'Deadwax Club');
  insert into public.record_pressings (id, album_id, dedupe_key)
  values (v_pressing_id, v_album_id, 'quota-check:' || v_pressing_id);

  -- First five creations succeed and increment the protected lifetime quota.
  for i in 1..5 loop
    v_record_id := gen_random_uuid();
    insert into public.records (id, record_pressing_id, collection_id, created_by, status)
    values (v_record_id, v_pressing_id, v_collection_id, null, 'owned');
    v_record_ids := array_append(v_record_ids, v_record_id);
  end loop;
  select lifetime_record_count into v_count
  from public.record_creation_quotas where user_id = v_user_id;
  if v_count <> 5 then raise exception 'Expected quota 5, got %', v_count; end if;

  -- Sixth creation reports the stable, app-specific SQLSTATE, not a message.
  v_failed := false;
  begin
    insert into public.records (id, record_pressing_id, collection_id, status)
    values (gen_random_uuid(), v_pressing_id, v_collection_id, 'owned');
  exception when sqlstate 'DW001' then v_failed := true;
  end;
  if not v_failed then raise exception 'Expected sixth creation to fail with DW001'; end if;

  -- Neither a soft delete nor a hard delete reopens a free lifetime slot.
  update public.records set deleted_at = now() where id = v_record_ids[1];
  v_failed := false;
  begin
    insert into public.records (id, record_pressing_id, collection_id, status)
    values (gen_random_uuid(), v_pressing_id, v_collection_id, 'owned');
  exception when sqlstate 'DW001' then v_failed := true;
  end;
  if not v_failed then raise exception 'Soft delete restored quota'; end if;

  delete from public.records where id = v_record_ids[1];
  v_failed := false;
  begin
    insert into public.records (id, record_pressing_id, collection_id, status)
    values (gen_random_uuid(), v_pressing_id, v_collection_id, 'owned');
  exception when sqlstate 'DW001' then v_failed := true;
  end;
  if not v_failed then raise exception 'Hard delete restored quota'; end if;

  -- A replayed plain insert hits the durable event ledger and does not charge
  -- twice. The connector confirms this UUID exists before acknowledging 23505.
  v_failed := false;
  begin
    insert into public.records (id, record_pressing_id, collection_id, created_by, status, notes)
    values (v_record_ids[2], v_pressing_id, v_collection_id, v_user_id, 'owned', 'replay');
  exception when unique_violation then v_failed := true;
  end;
  if not v_failed then raise exception 'Duplicate replay unexpectedly inserted'; end if;
  select lifetime_record_count into v_count
  from public.record_creation_quotas where user_id = v_user_id;
  if v_count <> 5 then raise exception 'Duplicate replay consumed quota'; end if;

  -- The trigger derives the creator; spoofing or changing it is rejected.
  v_failed := false;
  begin
    insert into public.records (id, record_pressing_id, collection_id, created_by, status)
    values (gen_random_uuid(), v_pressing_id, v_collection_id, v_other_user_id, 'owned');
  exception when sqlstate 'DW002' then v_failed := true;
  end;
  if not v_failed then raise exception 'Spoofed creator was accepted'; end if;
  v_failed := false;
  begin
    update public.records set created_by = v_other_user_id where id = v_record_ids[2];
  exception when sqlstate 'DW002' then v_failed := true;
  end;
  if not v_failed then raise exception 'Creator reassignment was accepted'; end if;

  -- A legacy active row from the former decoded-payload implementation is
  -- historical only. Missing verification metadata must not bypass the cap.
  update public.profiles set is_premium_account = true where id = v_user_id;
  insert into public.records (id, record_pressing_id, collection_id, status)
  values (gen_random_uuid(), v_pressing_id, v_collection_id, 'owned');
  update public.profiles set is_premium_account = false where id = v_user_id;
  insert into public.iap_entitlements (user_id, product_id, status, expires_at)
  values (v_user_id, 'club.deadwax.supporter.monthly', 'active', now() + interval '1 day');
  v_failed := false;
  begin
    insert into public.records (id, record_pressing_id, collection_id, status)
    values (gen_random_uuid(), v_pressing_id, v_collection_id, 'owned');
  exception when sqlstate 'DW001' then v_failed := true;
  end;
  if not v_failed then raise exception 'Legacy unverified entitlement bypassed the free cap'; end if;

  -- The monthly product must always carry an Apple expiry date, including an
  -- active event. The service-role writer exposes DW003 for malformed claims.
  v_failed := false;
  begin
    perform public.apply_verified_iap_entitlement(
      v_user_id, 'com.deadwaxclub.app', 'club.deadwax.supporter.monthly',
      'missing-expiry-' || v_user_id, 'original-' || v_user_id, 'active',
      null, null, 'sandbox', v_signed_at, v_signed_at + interval '1 second',
      'storekit_transaction'
    );
  exception when sqlstate 'DW003' then v_failed := true;
  end;
  if not v_failed then raise exception 'Active monthly entitlement without expiry was accepted'; end if;

  -- A valid, active, unexpired event can update a legacy row and bypass the
  -- record cap. Subsequent checks exercise signed-time monotonic ordering.
  perform public.apply_verified_iap_entitlement(
    v_user_id, 'com.deadwaxclub.app', 'club.deadwax.supporter.monthly',
    'active-initial-' || v_user_id, 'original-' || v_user_id, 'active',
    now() + interval '1 day', null, 'sandbox', v_signed_at,
    v_signed_at + interval '1 second', 'storekit_transaction'
  );

  -- A newer revoke wins. An older active event received later cannot undo it.
  perform public.apply_verified_iap_entitlement(
    v_user_id, 'com.deadwaxclub.app', 'club.deadwax.supporter.monthly',
    'revoked-newer-' || v_user_id, 'original-' || v_user_id, 'revoked',
    now() + interval '1 day', now(), 'sandbox', v_signed_at + interval '2 minutes',
    v_signed_at + interval '2 minutes 1 second', 'app_store_server_notification'
  );
  perform public.apply_verified_iap_entitlement(
    v_user_id, 'com.deadwaxclub.app', 'club.deadwax.supporter.monthly',
    'active-older-' || v_user_id, 'original-' || v_user_id, 'active',
    now() + interval '1 day', null, 'sandbox', v_signed_at + interval '1 minute',
    v_signed_at + interval '1 minute 1 second', 'storekit_transaction'
  );
  select status, transaction_id into v_status, v_transaction_id
  from public.iap_entitlements where user_id = v_user_id;
  if v_status <> 'revoked' or v_transaction_id <> ('revoked-newer-' || v_user_id) then
    raise exception 'Older active event overwrote newer revoked state';
  end if;

  -- Equal signed timestamps are accepted, then a newer expiry wins. The
  -- earlier equal active event cannot overwrite that newer expired state.
  perform public.apply_verified_iap_entitlement(
    v_user_id, 'com.deadwaxclub.app', 'club.deadwax.supporter.monthly',
    'active-equal-' || v_user_id, 'original-' || v_user_id, 'active',
    now() + interval '1 day', null, 'sandbox', v_signed_at + interval '2 minutes',
    v_signed_at + interval '2 minutes 2 seconds', 'storekit_transaction'
  );
  select status, transaction_id into v_status, v_transaction_id
  from public.iap_entitlements where user_id = v_user_id;
  if v_status <> 'active' or v_transaction_id <> ('active-equal-' || v_user_id) then
    raise exception 'Equal signed event did not update entitlement state';
  end if;
  perform public.apply_verified_iap_entitlement(
    v_user_id, 'com.deadwaxclub.app', 'club.deadwax.supporter.monthly',
    'expired-newer-' || v_user_id, 'original-' || v_user_id, 'expired',
    now() - interval '1 day', null, 'sandbox', v_signed_at + interval '3 minutes',
    v_signed_at + interval '3 minutes 1 second', 'app_store_server_notification'
  );
  perform public.apply_verified_iap_entitlement(
    v_user_id, 'com.deadwaxclub.app', 'club.deadwax.supporter.monthly',
    'active-before-expiry-' || v_user_id, 'original-' || v_user_id, 'active',
    now() + interval '1 day', null, 'sandbox', v_signed_at + interval '2 minutes',
    v_signed_at + interval '2 minutes 3 seconds', 'storekit_transaction'
  );
  select status, transaction_id into v_status, v_transaction_id
  from public.iap_entitlements where user_id = v_user_id;
  if v_status <> 'expired' or v_transaction_id <> ('expired-newer-' || v_user_id) then
    raise exception 'Older active event overwrote newer expired state';
  end if;

  -- A newer signed active event can legitimately restore the current state.
  perform public.apply_verified_iap_entitlement(
    v_user_id, 'com.deadwaxclub.app', 'club.deadwax.supporter.monthly',
    'active-newer-' || v_user_id, 'original-' || v_user_id, 'active',
    now() + interval '1 day', null, 'sandbox', v_signed_at + interval '4 minutes',
    v_signed_at + interval '4 minutes 1 second', 'storekit_transaction'
  );
  select status, transaction_id into v_status, v_transaction_id
  from public.iap_entitlements where user_id = v_user_id;
  if v_status <> 'active' or v_transaction_id <> ('active-newer-' || v_user_id) then
    raise exception 'Newer signed active event did not update entitlement state';
  end if;

  -- The valid current active entitlement bypasses the record limit.
  insert into public.records (id, record_pressing_id, collection_id, status)
  values (gen_random_uuid(), v_pressing_id, v_collection_id, 'owned');
end
$checks$;

-- Every profile must have a materialized snapshot, including confirmed zero.
do $$ begin
  if exists (
    select 1 from public.profiles p
    left join public.record_creation_quotas q on q.user_id = p.id
    where q.user_id is null
  ) then raise exception 'Profile without initialized quota snapshot'; end if;
end $$;

-- Concurrent check: in two psql sessions, use the same free test user with
-- `lifetime_record_count = 4` and execute the INSERT below at the same time.
-- Exactly one session succeeds; the other returns DW001 and the final counter
-- is 5. This exercises the profile-row serialization in the trigger.
--
--   select set_config('request.jwt.claim.sub', '<user UUID>', false);
--   insert into public.records (id, record_pressing_id, collection_id, status)
--   values (gen_random_uuid(), '<pressing UUID>', '<collection UUID>', 'owned');

-- Migration deployment lock check: use two psql sessions against a disposable
-- database while 0027 is being applied. Session B must receive 55P03 rather
-- than insert between quota seeding and trigger installation, then can retry
-- after Session A commits:
--
--   -- Session A (the migration transaction):
--   begin;
--   lock table public.records in share row exclusive mode;
--   -- run 0027's historical attribution + quota seed + trigger statements
--   select pg_sleep(5); -- make the protected deployment window observable
--   commit;
--
--   -- Session B, during the sleep:
--   set lock_timeout = '250ms';
--   insert into public.records (id, record_pressing_id, collection_id, status)
--   values (gen_random_uuid(), '<pressing UUID>', '<collection UUID>', 'owned');
--   -- expected: ERROR 55P03 canceling statement due to lock timeout
--   -- After Session A commits, retry the same INSERT: it reaches the trigger
--   -- and is included in the protected quota count.

rollback;
