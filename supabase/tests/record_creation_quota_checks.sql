-- Reproducible checks for 0027_enforce_record_creation_limit.sql.
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

  -- A PostgREST/PowerSync upsert of an existing ID is an update, not a create.
  insert into public.records (id, record_pressing_id, collection_id, created_by, status, notes)
  values (v_record_ids[2], v_pressing_id, v_collection_id, v_user_id, 'owned', 'updated')
  on conflict (id) do update set notes = excluded.notes;
  select lifetime_record_count into v_count
  from public.record_creation_quotas where user_id = v_user_id;
  if v_count <> 5 then raise exception 'Existing-ID upsert consumed quota'; end if;

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
  exception when insufficient_privilege then v_failed := true;
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

  -- The same current entitlement only bypasses after a verified writer has
  -- supplied the exact bundle/product/environment/source contract.
  update public.iap_entitlements
  set bundle_id = 'com.deadwaxclub.app',
      transaction_id = 'quota-check-' || v_user_id,
      environment = 'sandbox',
      signed_at = now() - interval '1 minute',
      verified_at = now(),
      verification_source = 'storekit_transaction'
  where user_id = v_user_id;
  insert into public.records (id, record_pressing_id, collection_id, status)
  values (gen_random_uuid(), v_pressing_id, v_collection_id, 'owned');
end
$checks$;

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
