-- Deadwax Club application schema. Applied once, in order, by db/application.ts.
-- Better Auth tables come from drizzle/; recovery fencing from deploy/recovery-guard.sql.
set local check_function_bodies = false;

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public;

CREATE SCHEMA identity;

CREATE TYPE public.collection_member_role AS ENUM (
    'owner',
    'editor',
    'viewer'
);

CREATE TYPE public.list_member_role AS ENUM (
    'viewer',
    'editor'
);

CREATE TYPE public.list_share_mode AS ENUM (
    'private',
    'link_public',
    'invite',
    'collaborative'
);

CREATE TYPE public.notification_kind AS ENUM (
    'price_alert',
    'collection_invite'
);

CREATE TYPE public.record_image_kind AS ENUM (
    'discogs',
    'user_upload'
);

CREATE FUNCTION identity.sync_verified_identity() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
  if new.email_verified then
    insert into identity.users (id, email, metadata)
      values (new.id, new.email, jsonb_build_object('display_name', new.name))
      on conflict (id) do update set email = excluded.email;
  end if;
  return new;
end;
$$;

CREATE FUNCTION identity.user_id() RETURNS uuid
    LANGUAGE sql STABLE
    AS $$
  select nullif(current_setting('deadwax.user_id', true), '')::uuid
$$;

CREATE FUNCTION public.album_dedupe_key(p_title text, p_artist text, p_album_year integer) RETURNS text
    LANGUAGE sql IMMUTABLE
    AS $$
  select concat_ws(
    ':',
    'album',
    lower(btrim(coalesce(p_title, ''))),
    public.normalized_artist_sort_name(p_artist),
    coalesce(p_album_year::text, '')
  );
$$;

CREATE TABLE public.iap_entitlements (
    user_id uuid NOT NULL,
    product_id text NOT NULL,
    original_transaction_id text,
    status text NOT NULL,
    expires_at timestamp with time zone,
    revoked_at timestamp with time zone,
    environment text,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    bundle_id text,
    transaction_id text,
    signed_at timestamp with time zone,
    verified_at timestamp with time zone,
    verification_source text,
    CONSTRAINT iap_entitlements_status_check CHECK ((status = ANY (ARRAY['active'::text, 'expired'::text, 'revoked'::text, 'unknown'::text])))
);

CREATE FUNCTION public.apply_verified_iap_entitlement(p_user_id uuid, p_bundle_id text, p_product_id text, p_transaction_id text, p_original_transaction_id text, p_status text, p_expires_at timestamp with time zone, p_revoked_at timestamp with time zone, p_environment text, p_signed_at timestamp with time zone, p_verified_at timestamp with time zone, p_verification_source text) RETURNS public.iap_entitlements
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_entitlement public.iap_entitlements;
begin
  if current_setting('role', true) <> 'deadwax_service' then
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

CREATE TABLE public.lists (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    owner_id uuid NOT NULL,
    name text NOT NULL,
    description text,
    share_mode public.list_share_mode DEFAULT 'private'::public.list_share_mode NOT NULL,
    share_token text,
    cover_record_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone
);

CREATE FUNCTION public.can_read_list(list public.lists) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select
    list.deleted_at is null and (
      list.owner_id = identity.user_id()
      or list.share_mode = 'link_public'
      or exists (
        select 1 from public.list_members m
        where m.list_id = list.id and m.user_id = identity.user_id()
      )
    );
$$;

CREATE FUNCTION public.can_write_list(list public.lists) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select
    list.deleted_at is null and (
      list.owner_id = identity.user_id()
      or (
        list.share_mode in ('invite', 'collaborative')
        and exists (
          select 1 from public.list_members m
          where m.list_id = list.id
            and m.user_id = identity.user_id()
            and (m.role = 'editor' or list.share_mode = 'collaborative')
        )
      )
    );
$$;

CREATE FUNCTION public.compute_new_low() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
declare prev_min int;
begin
  select min(price_cents) into prev_min
  from public.price_entries
  where record_id = new.record_id
    and id <> new.id
    and deleted_at is null;

  new.previous_min_cents := prev_min;
  new.is_new_low := prev_min is null or new.price_cents < prev_min;
  return new;
end;
$$;

CREATE FUNCTION public.delete_my_account() RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'auth'
    AS $$
declare uid uuid := identity.user_id();
begin
  if uid is null then
    raise exception 'not authenticated';
  end if;

  -- Cascading FKs handle records, price_entries, lists, list_items, list_members,
  -- device_tokens. We just need to remove the identity.users row.
  delete from identity.users where id = uid;
end;
$$;

CREATE FUNCTION public.enforce_record_creation_limit() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_user_id uuid := identity.user_id();
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

CREATE FUNCTION public.get_collection_member_profiles(p_collection_id uuid) RETURNS TABLE(id uuid, display_name text)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'auth'
    AS $$
  select
    p.id,
    coalesce(
      nullif(btrim(p.display_name), ''),
      nullif(btrim(u.metadata->>'display_name'), ''),
      nullif(btrim(u.metadata->>'full_name'), ''),
      nullif(btrim(u.metadata->>'name'), ''),
      nullif(split_part(u.email, '@', 1), '')
    ) as display_name
  from public.collection_members cm
  join public.profiles p on p.id = cm.user_id
  join identity.users u on u.id = cm.user_id
  where cm.collection_id = p_collection_id
    and public.is_collection_member(p_collection_id)
  order by cm.joined_at asc;
$$;

CREATE FUNCTION public.get_record_creation_status() RETURNS TABLE(lifetime_record_count bigint, free_limit integer, has_verified_entitlement boolean)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare v_user_id uuid := identity.user_id();
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

CREATE FUNCTION public.get_shared_list(token text) RETURNS TABLE(id uuid, name text, description text, owner_display_name text, cover_record_id uuid, updated_at timestamp with time zone)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select l.id, l.name, l.description, p.display_name, l.cover_record_id, l.updated_at
  from public.lists l
  left join public.profiles p on p.id = l.owner_id
  where l.share_token = token and l.share_mode = 'link_public' and l.deleted_at is null;
$$;

CREATE FUNCTION public.get_shared_list_records(token text) RETURNS TABLE(id uuid, title text, artist text, year integer, colourway text, cover_art_storage_path text, cover_art_source_url text, "position" integer)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select r.id, a.title, a.artist, rp.year, rp.colourway,
         rp.cover_art_storage_path, rp.cover_art_source_url, li.position
  from public.lists l
  join public.list_items li on li.list_id = l.id
  join public.records r on r.id = li.record_id
  join public.record_pressings rp on rp.id = r.record_pressing_id
  join public.albums a on a.id = rp.album_id
  where l.share_token = token
    and l.share_mode = 'link_public'
    and l.deleted_at is null
    and r.deleted_at is null
  order by li.position asc, li.created_at asc;
$$;

CREATE FUNCTION public.initialize_new_user() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'auth'
    AS $$
declare
  v_display_name text;
  v_personal_id uuid;
begin
  v_display_name := coalesce(
    nullif(new.metadata->>'display_name', ''),
    nullif(new.metadata->>'given_name', ''),
    nullif(split_part(new.metadata->>'name', ' ', 1), ''),
    nullif(split_part(new.metadata->>'full_name', ' ', 1), ''),
    nullif(new.metadata->>'name', ''),
    nullif(new.metadata->>'full_name', '')
  );

  insert into public.profiles (id, display_name)
  values (new.id, v_display_name)
  on conflict (id) do nothing;

  if (select primary_collection_id from public.profiles where id = new.id) is null then
    insert into public.collections (name, created_by)
    values (
      coalesce(v_display_name || '''s Collection', 'My Collection'),
      new.id
    )
    returning id into v_personal_id;

    insert into public.collection_members (collection_id, user_id, role, invited_by)
    values (v_personal_id, new.id, 'owner', new.id);

    update public.profiles
    set primary_collection_id = v_personal_id
    where id = new.id;
  end if;

  insert into public.list_members (list_id, user_id, role, invited_by)
  select pi.list_id, new.id, pi.role, pi.invited_by
  from public.pending_invites pi
  where lower(pi.email) = lower(new.email)
    and pi.accepted_at is null
  on conflict (list_id, user_id) do nothing;

  update public.pending_invites
  set accepted_at = now()
  where lower(email) = lower(new.email) and accepted_at is null;

  insert into public.collection_members (collection_id, user_id, role, invited_by)
  select cpi.collection_id, new.id, cpi.role, cpi.invited_by
  from public.collection_pending_invites cpi
  where lower(cpi.email) = lower(new.email)
    and cpi.accepted_at is null
  on conflict (collection_id, user_id) do nothing;

  update public.collection_pending_invites
  set accepted_at = now()
  where lower(email) = lower(new.email) and accepted_at is null;

  return new;
end;
$$;

CREATE FUNCTION public.has_verified_deadwax_entitlement(p_user_id uuid) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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

CREATE FUNCTION public.initialize_collection_owner() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
  if identity.user_id() is not null and new.created_by = identity.user_id() then
    insert into public.collection_members (collection_id, user_id, role, invited_by)
      values (new.id, new.created_by, 'owner', new.created_by)
      on conflict (collection_id, user_id) do nothing;
  end if;
  return new;
end;
$$;

CREATE FUNCTION public.initialize_record_creation_quota() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  insert into public.record_creation_quotas (user_id, lifetime_record_count, updated_at)
  values (new.id, 0, statement_timestamp()) on conflict (user_id) do nothing;
  return new;
end;
$$;

CREATE FUNCTION public.invite_to_collection(p_collection_id uuid, p_email text, p_role text) RETURNS json
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'auth'
    AS $$
declare
  v_user_id uuid;
  v_role public.collection_member_role := p_role::public.collection_member_role;
  v_collection_name text;
  v_inviter_name text;
begin
  if p_email is null or trim(p_email) = '' then
    raise exception 'email required';
  end if;

  if not exists (
    select 1 from public.collection_members m
    where m.collection_id = p_collection_id
      and m.user_id = identity.user_id()
      and m.role = 'owner'
  ) then
    raise exception 'not authorized';
  end if;

  select c.name into v_collection_name
  from public.collections c
  where c.id = p_collection_id and c.deleted_at is null;

  if v_collection_name is null then
    raise exception 'collection not found';
  end if;

  select coalesce(p.display_name, 'Someone') into v_inviter_name
  from public.profiles p where p.id = identity.user_id();

  select id into v_user_id from identity.users where lower(email) = lower(p_email) limit 1;

  if v_user_id is not null then
    insert into public.collection_members (collection_id, user_id, role, invited_by)
    values (p_collection_id, v_user_id, v_role, identity.user_id())
    on conflict (collection_id, user_id) do update set role = excluded.role;

    insert into public.notifications (user_id, kind, title, body, payload)
    values (
      v_user_id,
      'collection_invite',
      v_collection_name,
      v_inviter_name || ' added you to this collection.',
      jsonb_build_object(
        'collection_id', p_collection_id,
        'inviter_id', identity.user_id(),
        'inviter_name', v_inviter_name
      )
    );

    return json_build_object('status', 'added', 'user_id', v_user_id);
  else
    insert into public.collection_pending_invites (collection_id, email, role, invited_by)
    values (p_collection_id, lower(p_email), v_role, identity.user_id())
    on conflict (collection_id, email) do update
      set role = excluded.role,
          accepted_at = null,
          created_at = now();
    return json_build_object('status', 'pending');
  end if;
end;
$$;

CREATE FUNCTION public.invite_to_list(p_list_id uuid, p_email text, p_role text) RETURNS json
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'auth'
    AS $$
declare
  v_user_id uuid;
  v_list_owner uuid;
  v_role list_member_role := p_role::list_member_role;
begin
  if p_email is null or trim(p_email) = '' then
    raise exception 'email required';
  end if;

  select owner_id into v_list_owner
  from public.lists where id = p_list_id and deleted_at is null;
  if v_list_owner is null then
    raise exception 'list not found';
  end if;
  if v_list_owner <> identity.user_id() then
    raise exception 'not authorized';
  end if;

  select id into v_user_id from identity.users where lower(email) = lower(p_email) limit 1;

  if v_user_id is not null then
    insert into public.list_members (list_id, user_id, role, invited_by)
    values (p_list_id, v_user_id, v_role, identity.user_id())
    on conflict (list_id, user_id) do update set role = excluded.role;
    return json_build_object('status', 'added', 'user_id', v_user_id);
  else
    insert into public.pending_invites (list_id, email, role, invited_by)
    values (p_list_id, lower(p_email), v_role, identity.user_id())
    on conflict (list_id, email) do update
      set role = excluded.role,
          accepted_at = null,
          created_at = now();
    return json_build_object('status', 'pending');
  end if;
end;
$$;

CREATE FUNCTION public.is_collection_member(p_collection_id uuid) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select exists (
    select 1 from public.collection_members
    where collection_id = p_collection_id and user_id = identity.user_id()
  );
$$;

CREATE FUNCTION public.is_collection_owner(p_collection_id uuid) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select exists (
    select 1 from public.collection_members
    where collection_id = p_collection_id
      and user_id = identity.user_id()
      and role = 'owner'
  );
$$;

CREATE FUNCTION public.is_collection_writer(p_collection_id uuid) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select exists (
    select 1 from public.collection_members
    where collection_id = p_collection_id
      and user_id = identity.user_id()
      and role in ('owner', 'editor')
  );
$$;

CREATE FUNCTION public.lookup_user_id_by_email(email_in text) RETURNS TABLE(user_id uuid)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'auth'
    AS $$
  select id from identity.users where lower(email) = lower(email_in) limit 1;
$$;

CREATE FUNCTION public.normalized_artist_sort_name(p_artist text) RETURNS text
    LANGUAGE sql IMMUTABLE
    AS $_$
  select regexp_replace(
    regexp_replace(lower(btrim(coalesce(p_artist, ''))), '\s+\([0-9]+\)$', ''),
    '^the\s+',
    ''
  );
$_$;

CREATE FUNCTION public.notification_audience_for_record(rid uuid) RETURNS TABLE(user_id uuid)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select cm.user_id
  from public.records r
  join public.collection_members cm on cm.collection_id = r.collection_id
  where r.id = rid and r.deleted_at is null
  union
  select m.user_id
  from public.list_items li
  join public.list_members m on m.list_id = li.list_id
  where li.record_id = rid;
$$;

CREATE FUNCTION public.prevent_record_creator_change() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
begin
  if new.created_by is distinct from old.created_by then
    raise exception 'Record creator cannot be changed' using errcode = 'DW002';
  end if;
  return new;
end;
$$;

CREATE FUNCTION public.record_pressing_dedupe_key(p_album_id uuid, p_record_year integer, p_colourway text, p_discogs_release_id bigint, p_barcode text) RETURNS text
    LANGUAGE sql IMMUTABLE
    AS $$
  select case
    when p_discogs_release_id is not null then 'discogs:' || p_discogs_release_id::text
    when nullif(btrim(coalesce(p_barcode, '')), '') is not null then 'barcode:' || lower(btrim(p_barcode))
    else concat_ws(
      ':',
      'pressing',
      p_album_id::text,
      lower(btrim(coalesce(p_colourway, ''))),
      coalesce(p_record_year::text, '')
    )
  end;
$$;

CREATE FUNCTION public.revoke_collection_invite(p_invite_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  delete from public.collection_pending_invites cpi
  using public.collection_members m
  where cpi.id = p_invite_id
    and m.collection_id = cpi.collection_id
    and m.user_id = identity.user_id()
    and m.role = 'owner';
end;
$$;

CREATE FUNCTION public.revoke_pending_invite(p_invite_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  delete from public.pending_invites pi
  using public.lists l
  where pi.id = p_invite_id
    and pi.list_id = l.id
    and l.owner_id = identity.user_id();
end;
$$;

CREATE FUNCTION public.stable_catalog_uuid(p_key text) RETURNS uuid
    LANGUAGE sql IMMUTABLE
    AS $$
  with h as (
    select encode(digest(p_key, 'sha256'), 'hex') as value
  )
  select (
    substr(value, 1, 8) || '-' ||
    substr(value, 9, 4) || '-' ||
    '5' || substr(value, 14, 3) || '-' ||
    '8' || substr(value, 18, 3) || '-' ||
    substr(value, 21, 12)
  )::uuid
  from h;
$$;

CREATE FUNCTION public.touch_updated_at() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
begin
  new.updated_at = now();
  return new;
end;
$$;

CREATE TABLE identity.users (
    id uuid NOT NULL,
    email text NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL
);

CREATE TABLE public.albums (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    dedupe_key text NOT NULL,
    title text NOT NULL,
    artist text NOT NULL,
    album_year integer,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.collection_members (
    collection_id uuid NOT NULL,
    user_id uuid NOT NULL,
    role public.collection_member_role DEFAULT 'editor'::public.collection_member_role NOT NULL,
    invited_by uuid,
    joined_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.collection_pending_invites (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    collection_id uuid NOT NULL,
    email text NOT NULL,
    role public.collection_member_role DEFAULT 'editor'::public.collection_member_role NOT NULL,
    invited_by uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    accepted_at timestamp with time zone
);

CREATE TABLE public.collections (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    created_by uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone
);

CREATE TABLE public.cover_objects (
    path text NOT NULL,
    pressing_id uuid NOT NULL,
    bytes bytea NOT NULL,
    CONSTRAINT cover_objects_bytes_check CHECK (((octet_length(bytes) >= 3) AND (octet_length(bytes) <= 5242880)))
);

CREATE TABLE public.device_tokens (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    apns_token text NOT NULL,
    device_name text,
    bundle_id text NOT NULL,
    environment text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT device_tokens_environment_check CHECK ((environment = ANY (ARRAY['sandbox'::text, 'production'::text])))
);

CREATE TABLE public.list_items (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    list_id uuid NOT NULL,
    record_id uuid NOT NULL,
    added_by uuid NOT NULL,
    "position" integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.list_members (
    list_id uuid NOT NULL,
    user_id uuid NOT NULL,
    role public.list_member_role DEFAULT 'viewer'::public.list_member_role NOT NULL,
    invited_by uuid,
    joined_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.native_codes (
    id text NOT NULL,
    challenge text NOT NULL,
    session_token text NOT NULL,
    expires_at timestamp with time zone NOT NULL
);

CREATE TABLE public.notifications (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    kind public.notification_kind NOT NULL,
    title text NOT NULL,
    body text NOT NULL,
    payload jsonb DEFAULT '{}'::jsonb NOT NULL,
    read_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.pending_invites (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    list_id uuid NOT NULL,
    email text NOT NULL,
    role public.list_member_role DEFAULT 'viewer'::public.list_member_role NOT NULL,
    invited_by uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    accepted_at timestamp with time zone
);

CREATE TABLE public.price_entries (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    record_id uuid NOT NULL,
    owner_id uuid NOT NULL,
    price_cents integer NOT NULL,
    currency text DEFAULT 'GBP'::text NOT NULL,
    shop_name text,
    scanned_at timestamp with time zone DEFAULT now() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    previous_min_cents integer,
    is_new_low boolean DEFAULT false NOT NULL,
    collection_id uuid NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    CONSTRAINT price_entries_currency_check CHECK ((length(currency) = 3)),
    CONSTRAINT price_entries_price_cents_check CHECK ((price_cents >= 0))
);

CREATE TABLE public.profiles (
    id uuid NOT NULL,
    display_name text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    primary_collection_id uuid,
    is_premium_account boolean DEFAULT false NOT NULL
);

CREATE TABLE public.record_creation_events (
    record_id uuid NOT NULL,
    user_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);

ALTER TABLE ONLY public.record_creation_events FORCE ROW LEVEL SECURITY;

CREATE TABLE public.record_creation_quotas (
    user_id uuid NOT NULL,
    lifetime_record_count bigint DEFAULT 0 NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT record_creation_quotas_lifetime_record_count_check CHECK ((lifetime_record_count >= 0))
);

CREATE TABLE public.record_images (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    record_id uuid NOT NULL,
    collection_id uuid NOT NULL,
    kind public.record_image_kind NOT NULL,
    "position" integer DEFAULT 0 NOT NULL,
    source_url text,
    storage_path text,
    uploaded_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.record_pressings (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    album_id uuid NOT NULL,
    dedupe_key text NOT NULL,
    year integer,
    colourway text,
    cover_art_source_url text,
    cover_art_storage_path text,
    discogs_release_id bigint,
    barcode text,
    estimated_price_cents integer,
    estimated_price_currency text,
    estimated_price_updated_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.records (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    status text NOT NULL,
    notes text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    collection_id uuid NOT NULL,
    record_pressing_id uuid,
    created_by uuid,
    CONSTRAINT records_status_check CHECK ((status = ANY (ARRAY['owned'::text, 'wishlist'::text])))
);

ALTER TABLE ONLY identity.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.albums
    ADD CONSTRAINT albums_dedupe_key_key UNIQUE (dedupe_key);

ALTER TABLE ONLY public.albums
    ADD CONSTRAINT albums_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.collection_members
    ADD CONSTRAINT collection_members_pkey PRIMARY KEY (collection_id, user_id);

ALTER TABLE ONLY public.collection_pending_invites
    ADD CONSTRAINT collection_pending_invites_collection_id_email_key UNIQUE (collection_id, email);

ALTER TABLE ONLY public.collection_pending_invites
    ADD CONSTRAINT collection_pending_invites_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.collections
    ADD CONSTRAINT collections_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.cover_objects
    ADD CONSTRAINT cover_objects_pkey PRIMARY KEY (path);

ALTER TABLE ONLY public.device_tokens
    ADD CONSTRAINT device_tokens_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.device_tokens
    ADD CONSTRAINT device_tokens_user_id_apns_token_key UNIQUE (user_id, apns_token);

ALTER TABLE ONLY public.iap_entitlements
    ADD CONSTRAINT iap_entitlements_pkey PRIMARY KEY (user_id);

ALTER TABLE ONLY public.list_items
    ADD CONSTRAINT list_items_list_id_record_id_key UNIQUE (list_id, record_id);

ALTER TABLE ONLY public.list_items
    ADD CONSTRAINT list_items_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.list_members
    ADD CONSTRAINT list_members_pkey PRIMARY KEY (list_id, user_id);

ALTER TABLE ONLY public.lists
    ADD CONSTRAINT lists_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.lists
    ADD CONSTRAINT lists_share_token_key UNIQUE (share_token);

ALTER TABLE ONLY public.native_codes
    ADD CONSTRAINT native_codes_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT notifications_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.pending_invites
    ADD CONSTRAINT pending_invites_list_id_email_key UNIQUE (list_id, email);

ALTER TABLE ONLY public.pending_invites
    ADD CONSTRAINT pending_invites_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.price_entries
    ADD CONSTRAINT price_entries_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.profiles
    ADD CONSTRAINT profiles_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.record_creation_events
    ADD CONSTRAINT record_creation_events_pkey PRIMARY KEY (record_id);

ALTER TABLE ONLY public.record_creation_quotas
    ADD CONSTRAINT record_creation_quotas_pkey PRIMARY KEY (user_id);

ALTER TABLE ONLY public.record_images
    ADD CONSTRAINT record_images_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.record_pressings
    ADD CONSTRAINT record_pressings_dedupe_key_key UNIQUE (dedupe_key);

ALTER TABLE ONLY public.record_pressings
    ADD CONSTRAINT record_pressings_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.records
    ADD CONSTRAINT records_pkey PRIMARY KEY (id);

CREATE INDEX albums_artist_title_idx ON public.albums USING btree (artist, title);

CREATE INDEX collection_members_user_idx ON public.collection_members USING btree (user_id);

CREATE INDEX collection_pending_invites_email_idx ON public.collection_pending_invites USING btree (lower(email)) WHERE (accepted_at IS NULL);

CREATE INDEX collections_created_by_idx ON public.collections USING btree (created_by) WHERE (deleted_at IS NULL);

CREATE INDEX device_tokens_user_idx ON public.device_tokens USING btree (user_id);

CREATE INDEX iap_entitlements_status_idx ON public.iap_entitlements USING btree (status, expires_at);

CREATE UNIQUE INDEX iap_entitlements_transaction_id_idx ON public.iap_entitlements USING btree (transaction_id) WHERE (transaction_id IS NOT NULL);

CREATE INDEX list_items_list_idx ON public.list_items USING btree (list_id, "position");

CREATE INDEX list_members_user_idx ON public.list_members USING btree (user_id);

CREATE INDEX lists_owner_idx ON public.lists USING btree (owner_id) WHERE (deleted_at IS NULL);

CREATE INDEX notifications_user_idx ON public.notifications USING btree (user_id, created_at DESC);

CREATE INDEX notifications_user_unread_idx ON public.notifications USING btree (user_id, created_at DESC) WHERE (read_at IS NULL);

CREATE INDEX pending_invites_email_idx ON public.pending_invites USING btree (lower(email)) WHERE (accepted_at IS NULL);

CREATE INDEX price_entries_collection_idx ON public.price_entries USING btree (collection_id, scanned_at DESC);

CREATE INDEX price_entries_record_idx ON public.price_entries USING btree (record_id, scanned_at DESC);

CREATE INDEX record_creation_events_user_id_idx ON public.record_creation_events USING btree (user_id);

CREATE INDEX record_images_collection_idx ON public.record_images USING btree (collection_id);

CREATE INDEX record_images_record_idx ON public.record_images USING btree (record_id, "position");

CREATE INDEX record_pressings_album_idx ON public.record_pressings USING btree (album_id);

CREATE INDEX record_pressings_barcode_idx ON public.record_pressings USING btree (barcode) WHERE (barcode IS NOT NULL);

CREATE INDEX record_pressings_discogs_release_idx ON public.record_pressings USING btree (discogs_release_id) WHERE (discogs_release_id IS NOT NULL);

CREATE INDEX records_collection_status_idx ON public.records USING btree (collection_id, status) WHERE (deleted_at IS NULL);

CREATE INDEX records_created_by_idx ON public.records USING btree (created_by) WHERE (deleted_at IS NULL);

CREATE INDEX records_created_by_updated_at_idx ON public.records USING btree (created_by, updated_at DESC);

CREATE INDEX records_record_pressing_idx ON public.records USING btree (record_pressing_id) WHERE (deleted_at IS NULL);

CREATE TRIGGER initialize_new_user AFTER INSERT ON identity.users FOR EACH ROW EXECUTE FUNCTION public.initialize_new_user();

CREATE TRIGGER albums_touch_updated_at BEFORE UPDATE ON public.albums FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

CREATE TRIGGER collections_initialize_owner AFTER INSERT ON public.collections FOR EACH ROW EXECUTE FUNCTION public.initialize_collection_owner();

CREATE TRIGGER collections_touch_updated_at BEFORE UPDATE ON public.collections FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

CREATE TRIGGER device_tokens_touch_updated_at BEFORE UPDATE ON public.device_tokens FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

CREATE TRIGGER iap_entitlements_touch_updated_at BEFORE UPDATE ON public.iap_entitlements FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

CREATE TRIGGER lists_touch_updated_at BEFORE UPDATE ON public.lists FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

CREATE TRIGGER price_entries_compute_new_low BEFORE INSERT ON public.price_entries FOR EACH ROW EXECUTE FUNCTION public.compute_new_low();

CREATE TRIGGER price_entries_touch_updated_at BEFORE UPDATE ON public.price_entries FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

CREATE TRIGGER profiles_initialize_record_creation_quota AFTER INSERT ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.initialize_record_creation_quota();

CREATE TRIGGER profiles_touch_updated_at BEFORE UPDATE ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

CREATE TRIGGER record_pressings_touch_updated_at BEFORE UPDATE ON public.record_pressings FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

CREATE TRIGGER records_enforce_creation_limit BEFORE INSERT ON public.records FOR EACH ROW EXECUTE FUNCTION public.enforce_record_creation_limit();

CREATE TRIGGER records_prevent_creator_change BEFORE UPDATE OF created_by ON public.records FOR EACH ROW EXECUTE FUNCTION public.prevent_record_creator_change();

CREATE TRIGGER records_touch_updated_at BEFORE UPDATE ON public.records FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

CREATE TRIGGER sync_verified_identity AFTER INSERT OR UPDATE OF email_verified, email ON public.auth_user FOR EACH ROW EXECUTE FUNCTION identity.sync_verified_identity();

ALTER TABLE ONLY identity.users
    ADD CONSTRAINT users_id_fkey FOREIGN KEY (id) REFERENCES public.auth_user(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.collection_members
    ADD CONSTRAINT collection_members_collection_id_fkey FOREIGN KEY (collection_id) REFERENCES public.collections(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.collection_members
    ADD CONSTRAINT collection_members_invited_by_fkey FOREIGN KEY (invited_by) REFERENCES public.profiles(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.collection_members
    ADD CONSTRAINT collection_members_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.collection_pending_invites
    ADD CONSTRAINT collection_pending_invites_collection_id_fkey FOREIGN KEY (collection_id) REFERENCES public.collections(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.collection_pending_invites
    ADD CONSTRAINT collection_pending_invites_invited_by_fkey FOREIGN KEY (invited_by) REFERENCES public.profiles(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.collections
    ADD CONSTRAINT collections_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.profiles(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.device_tokens
    ADD CONSTRAINT device_tokens_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.iap_entitlements
    ADD CONSTRAINT iap_entitlements_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.list_items
    ADD CONSTRAINT list_items_added_by_fkey FOREIGN KEY (added_by) REFERENCES public.profiles(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.list_items
    ADD CONSTRAINT list_items_list_id_fkey FOREIGN KEY (list_id) REFERENCES public.lists(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.list_items
    ADD CONSTRAINT list_items_record_id_fkey FOREIGN KEY (record_id) REFERENCES public.records(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.list_members
    ADD CONSTRAINT list_members_invited_by_fkey FOREIGN KEY (invited_by) REFERENCES public.profiles(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.list_members
    ADD CONSTRAINT list_members_list_id_fkey FOREIGN KEY (list_id) REFERENCES public.lists(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.list_members
    ADD CONSTRAINT list_members_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.lists
    ADD CONSTRAINT lists_cover_record_id_fkey FOREIGN KEY (cover_record_id) REFERENCES public.records(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.lists
    ADD CONSTRAINT lists_owner_id_fkey FOREIGN KEY (owner_id) REFERENCES public.profiles(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT notifications_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.pending_invites
    ADD CONSTRAINT pending_invites_invited_by_fkey FOREIGN KEY (invited_by) REFERENCES public.profiles(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.pending_invites
    ADD CONSTRAINT pending_invites_list_id_fkey FOREIGN KEY (list_id) REFERENCES public.lists(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.price_entries
    ADD CONSTRAINT price_entries_collection_id_fkey FOREIGN KEY (collection_id) REFERENCES public.collections(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.price_entries
    ADD CONSTRAINT price_entries_owner_id_fkey FOREIGN KEY (owner_id) REFERENCES public.profiles(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.price_entries
    ADD CONSTRAINT price_entries_record_id_fkey FOREIGN KEY (record_id) REFERENCES public.records(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.profiles
    ADD CONSTRAINT profiles_id_fkey FOREIGN KEY (id) REFERENCES identity.users(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.profiles
    ADD CONSTRAINT profiles_primary_collection_id_fkey FOREIGN KEY (primary_collection_id) REFERENCES public.collections(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.record_creation_events
    ADD CONSTRAINT record_creation_events_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.record_creation_quotas
    ADD CONSTRAINT record_creation_quotas_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.record_images
    ADD CONSTRAINT record_images_collection_id_fkey FOREIGN KEY (collection_id) REFERENCES public.collections(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.record_images
    ADD CONSTRAINT record_images_record_id_fkey FOREIGN KEY (record_id) REFERENCES public.records(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.record_images
    ADD CONSTRAINT record_images_uploaded_by_fkey FOREIGN KEY (uploaded_by) REFERENCES public.profiles(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.record_pressings
    ADD CONSTRAINT record_pressings_album_id_fkey FOREIGN KEY (album_id) REFERENCES public.albums(id) ON DELETE RESTRICT;

ALTER TABLE ONLY public.records
    ADD CONSTRAINT records_collection_id_fkey FOREIGN KEY (collection_id) REFERENCES public.collections(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.records
    ADD CONSTRAINT records_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.profiles(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.records
    ADD CONSTRAINT records_record_pressing_id_fkey FOREIGN KEY (record_pressing_id) REFERENCES public.record_pressings(id) ON DELETE RESTRICT;

CREATE POLICY own_identity ON identity.users FOR SELECT TO deadwax_api USING ((id = identity.user_id()));

ALTER TABLE identity.users ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.albums ENABLE ROW LEVEL SECURITY;

CREATE POLICY "albums authenticated insert" ON public.albums FOR INSERT WITH CHECK ((identity.user_id() IS NOT NULL));

CREATE POLICY "albums authenticated read" ON public.albums FOR SELECT USING ((identity.user_id() IS NOT NULL));

CREATE POLICY "albums authenticated update" ON public.albums FOR UPDATE USING ((identity.user_id() IS NOT NULL)) WITH CHECK ((identity.user_id() IS NOT NULL));

ALTER TABLE public.collection_members ENABLE ROW LEVEL SECURITY;

CREATE POLICY "collection_members read" ON public.collection_members FOR SELECT USING (public.is_collection_member(collection_id));

CREATE POLICY "collection_members write owner" ON public.collection_members USING ((public.is_collection_owner(collection_id) OR (user_id = identity.user_id()))) WITH CHECK ((public.is_collection_owner(collection_id) OR (user_id = identity.user_id())));

ALTER TABLE public.collection_pending_invites ENABLE ROW LEVEL SECURITY;

CREATE POLICY "collection_pending_invites by email" ON public.collection_pending_invites FOR SELECT USING ((lower(email) = lower(( SELECT users.email
   FROM identity.users
  WHERE (users.id = identity.user_id())))));

CREATE POLICY "collection_pending_invites owner all" ON public.collection_pending_invites USING (public.is_collection_owner(collection_id)) WITH CHECK (public.is_collection_owner(collection_id));

ALTER TABLE public.collections ENABLE ROW LEVEL SECURITY;

CREATE POLICY "collections read member" ON public.collections FOR SELECT USING (((deleted_at IS NULL) AND public.is_collection_member(id)));

CREATE POLICY "collections write owner" ON public.collections USING (public.is_collection_owner(id)) WITH CHECK (((created_by = identity.user_id()) OR public.is_collection_owner(id)));

ALTER TABLE public.cover_objects ENABLE ROW LEVEL SECURITY;

CREATE POLICY cover_read ON public.cover_objects FOR SELECT TO deadwax_api, deadwax_anon USING (true);

CREATE POLICY cover_write ON public.cover_objects TO deadwax_api USING ((EXISTS ( SELECT 1
   FROM public.records
  WHERE ((records.record_pressing_id = cover_objects.pressing_id) AND (records.deleted_at IS NULL) AND public.is_collection_writer(records.collection_id))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM public.records
  WHERE ((records.record_pressing_id = cover_objects.pressing_id) AND (records.deleted_at IS NULL) AND public.is_collection_writer(records.collection_id)))));

ALTER TABLE public.device_tokens ENABLE ROW LEVEL SECURITY;

CREATE POLICY "device_tokens self" ON public.device_tokens USING ((user_id = identity.user_id())) WITH CHECK ((user_id = identity.user_id()));

ALTER TABLE public.iap_entitlements ENABLE ROW LEVEL SECURITY;

CREATE POLICY "iap_entitlements read own" ON public.iap_entitlements FOR SELECT USING ((user_id = identity.user_id()));

ALTER TABLE public.list_items ENABLE ROW LEVEL SECURITY;

CREATE POLICY "list_items read" ON public.list_items FOR SELECT USING ((EXISTS ( SELECT 1
   FROM public.lists l
  WHERE ((l.id = list_items.list_id) AND public.can_read_list(l.*)))));

CREATE POLICY "list_items write" ON public.list_items USING ((EXISTS ( SELECT 1
   FROM public.lists l
  WHERE ((l.id = list_items.list_id) AND public.can_write_list(l.*))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM public.lists l
  WHERE ((l.id = list_items.list_id) AND public.can_write_list(l.*)))));

ALTER TABLE public.list_members ENABLE ROW LEVEL SECURITY;

CREATE POLICY "list_members read" ON public.list_members FOR SELECT USING ((EXISTS ( SELECT 1
   FROM public.lists l
  WHERE ((l.id = list_members.list_id) AND public.can_read_list(l.*)))));

CREATE POLICY "list_members write owner" ON public.list_members USING ((EXISTS ( SELECT 1
   FROM public.lists l
  WHERE ((l.id = list_members.list_id) AND (l.owner_id = identity.user_id()))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM public.lists l
  WHERE ((l.id = list_members.list_id) AND (l.owner_id = identity.user_id())))));

ALTER TABLE public.lists ENABLE ROW LEVEL SECURITY;

CREATE POLICY "lists read" ON public.lists FOR SELECT USING (public.can_read_list(lists.*));

CREATE POLICY "lists write owner" ON public.lists USING ((owner_id = identity.user_id())) WITH CHECK ((owner_id = identity.user_id()));

ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;

CREATE POLICY "notifications self" ON public.notifications USING ((user_id = identity.user_id())) WITH CHECK ((user_id = identity.user_id()));

ALTER TABLE public.pending_invites ENABLE ROW LEVEL SECURITY;

CREATE POLICY "pending_invites by email" ON public.pending_invites FOR SELECT USING ((lower(email) = lower(( SELECT users.email
   FROM identity.users
  WHERE (users.id = identity.user_id())))));

CREATE POLICY "pending_invites owner all" ON public.pending_invites USING ((EXISTS ( SELECT 1
   FROM public.lists l
  WHERE ((l.id = pending_invites.list_id) AND (l.owner_id = identity.user_id()))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM public.lists l
  WHERE ((l.id = pending_invites.list_id) AND (l.owner_id = identity.user_id())))));

ALTER TABLE public.price_entries ENABLE ROW LEVEL SECURITY;

CREATE POLICY "price_entries member rw" ON public.price_entries USING (public.is_collection_member(collection_id)) WITH CHECK (public.is_collection_writer(collection_id));

ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

CREATE POLICY "profiles insert own" ON public.profiles FOR INSERT WITH CHECK ((id = identity.user_id()));

CREATE POLICY "profiles read own" ON public.profiles FOR SELECT USING ((id = identity.user_id()));

CREATE POLICY "profiles update own" ON public.profiles FOR UPDATE USING ((id = identity.user_id())) WITH CHECK ((id = identity.user_id()));

CREATE POLICY "record pressings authenticated insert" ON public.record_pressings FOR INSERT WITH CHECK ((identity.user_id() IS NOT NULL));

CREATE POLICY "record pressings authenticated read" ON public.record_pressings FOR SELECT USING ((identity.user_id() IS NOT NULL));

CREATE POLICY "record pressings authenticated update" ON public.record_pressings FOR UPDATE USING ((identity.user_id() IS NOT NULL)) WITH CHECK ((identity.user_id() IS NOT NULL));

ALTER TABLE public.record_creation_events ENABLE ROW LEVEL SECURITY;

CREATE POLICY record_creation_events_owner ON public.record_creation_events TO deadwaxclub_owner USING (true) WITH CHECK (true);

ALTER TABLE public.record_creation_quotas ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.record_images ENABLE ROW LEVEL SECURITY;

CREATE POLICY "record_images member rw" ON public.record_images USING (public.is_collection_member(collection_id)) WITH CHECK (public.is_collection_writer(collection_id));

ALTER TABLE public.record_pressings ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.records ENABLE ROW LEVEL SECURITY;

CREATE POLICY "records member rw" ON public.records USING (public.is_collection_member(collection_id)) WITH CHECK (public.is_collection_writer(collection_id));

GRANT USAGE ON SCHEMA identity TO deadwax_api;
GRANT USAGE ON SCHEMA identity TO deadwax_service;

REVOKE USAGE ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO deadwax_runtime;
GRANT USAGE ON SCHEMA public TO deadwax_api;
GRANT USAGE ON SCHEMA public TO deadwax_anon;
GRANT USAGE ON SCHEMA public TO deadwax_service;
GRANT USAGE ON SCHEMA public TO deadwaxclub_recovery;

REVOKE ALL ON FUNCTION public.apply_verified_iap_entitlement(p_user_id uuid, p_bundle_id text, p_product_id text, p_transaction_id text, p_original_transaction_id text, p_status text, p_expires_at timestamp with time zone, p_revoked_at timestamp with time zone, p_environment text, p_signed_at timestamp with time zone, p_verified_at timestamp with time zone, p_verification_source text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.apply_verified_iap_entitlement(p_user_id uuid, p_bundle_id text, p_product_id text, p_transaction_id text, p_original_transaction_id text, p_status text, p_expires_at timestamp with time zone, p_revoked_at timestamp with time zone, p_environment text, p_signed_at timestamp with time zone, p_verified_at timestamp with time zone, p_verification_source text) TO deadwax_service;

GRANT SELECT,INSERT,UPDATE ON TABLE public.lists TO deadwax_api;

REVOKE ALL ON FUNCTION public.delete_my_account() FROM PUBLIC;
GRANT ALL ON FUNCTION public.delete_my_account() TO deadwax_api;

REVOKE ALL ON FUNCTION public.enforce_record_creation_limit() FROM PUBLIC;

GRANT ALL ON FUNCTION public.get_collection_member_profiles(p_collection_id uuid) TO deadwax_api;

REVOKE ALL ON FUNCTION public.get_record_creation_status() FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_record_creation_status() TO deadwax_api;

GRANT ALL ON FUNCTION public.get_shared_list(token text) TO deadwax_anon;
GRANT ALL ON FUNCTION public.get_shared_list(token text) TO deadwax_api;

GRANT ALL ON FUNCTION public.get_shared_list_records(token text) TO deadwax_anon;
GRANT ALL ON FUNCTION public.get_shared_list_records(token text) TO deadwax_api;

REVOKE ALL ON FUNCTION public.has_verified_deadwax_entitlement(p_user_id uuid) FROM PUBLIC;

REVOKE ALL ON FUNCTION public.initialize_collection_owner() FROM PUBLIC;

REVOKE ALL ON FUNCTION public.initialize_record_creation_quota() FROM PUBLIC;

REVOKE ALL ON FUNCTION public.invite_to_collection(p_collection_id uuid, p_email text, p_role text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.invite_to_collection(p_collection_id uuid, p_email text, p_role text) TO deadwax_api;

REVOKE ALL ON FUNCTION public.invite_to_list(p_list_id uuid, p_email text, p_role text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.invite_to_list(p_list_id uuid, p_email text, p_role text) TO deadwax_api;

GRANT ALL ON FUNCTION public.is_collection_member(p_collection_id uuid) TO deadwax_api;

GRANT ALL ON FUNCTION public.is_collection_owner(p_collection_id uuid) TO deadwax_api;

GRANT ALL ON FUNCTION public.is_collection_writer(p_collection_id uuid) TO deadwax_api;

REVOKE ALL ON FUNCTION public.lookup_user_id_by_email(email_in text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.lookup_user_id_by_email(email_in text) TO deadwax_api;

GRANT ALL ON FUNCTION public.notification_audience_for_record(rid uuid) TO deadwax_api;
GRANT ALL ON FUNCTION public.notification_audience_for_record(rid uuid) TO deadwax_service;

REVOKE ALL ON FUNCTION public.prevent_record_creator_change() FROM PUBLIC;

REVOKE ALL ON FUNCTION public.revoke_collection_invite(p_invite_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.revoke_collection_invite(p_invite_id uuid) TO deadwax_api;

GRANT ALL ON FUNCTION public.revoke_pending_invite(p_invite_id uuid) TO deadwax_api;

GRANT SELECT(id) ON TABLE identity.users TO deadwax_api;

GRANT SELECT(email) ON TABLE identity.users TO deadwax_api;

GRANT SELECT,INSERT,UPDATE ON TABLE public.albums TO deadwax_api;

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.auth_account TO deadwax_runtime;

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.auth_email_limit TO deadwax_runtime;

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.auth_jwks TO deadwax_runtime;

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.auth_rate_limit TO deadwax_runtime;

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.auth_session TO deadwax_runtime;

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.auth_user TO deadwax_runtime;

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.auth_verification TO deadwax_runtime;

GRANT SELECT,DELETE ON TABLE public.collection_members TO deadwax_api;

GRANT SELECT ON TABLE public.collection_pending_invites TO deadwax_api;

GRANT SELECT,INSERT,UPDATE ON TABLE public.collections TO deadwax_api;

GRANT SELECT ON TABLE public.cover_objects TO deadwax_anon;
GRANT SELECT,INSERT,UPDATE ON TABLE public.cover_objects TO deadwax_api;

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.device_tokens TO deadwax_api;

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.list_items TO deadwax_api;

GRANT SELECT,DELETE ON TABLE public.list_members TO deadwax_api;

GRANT SELECT,INSERT,DELETE ON TABLE public.native_codes TO deadwax_runtime;

GRANT SELECT ON TABLE public.notifications TO deadwax_api;

GRANT UPDATE(read_at) ON TABLE public.notifications TO deadwax_api;

GRANT SELECT ON TABLE public.pending_invites TO deadwax_api;

GRANT SELECT,INSERT,UPDATE ON TABLE public.price_entries TO deadwax_api;

GRANT SELECT ON TABLE public.profiles TO deadwax_api;

GRANT UPDATE(display_name) ON TABLE public.profiles TO deadwax_api;

GRANT UPDATE(primary_collection_id) ON TABLE public.profiles TO deadwax_api;

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.record_images TO deadwax_api;

GRANT SELECT,INSERT,UPDATE ON TABLE public.record_pressings TO deadwax_api;

GRANT SELECT,INSERT,UPDATE ON TABLE public.records TO deadwax_api;

ALTER DEFAULT PRIVILEGES FOR ROLE deadwaxclub_owner IN SCHEMA public GRANT SELECT,USAGE ON SEQUENCES TO deadwaxclub_runtime;

ALTER DEFAULT PRIVILEGES FOR ROLE deadwaxclub_owner IN SCHEMA public GRANT SELECT,INSERT,DELETE,UPDATE ON TABLES TO deadwaxclub_runtime;

-- Request-time helpers are callable by every role that can connect.
GRANT EXECUTE ON FUNCTION identity.user_id() TO PUBLIC;
GRANT EXECUTE ON FUNCTION identity.sync_verified_identity() TO PUBLIC;
GRANT EXECUTE ON FUNCTION public.touch_updated_at() TO PUBLIC;
GRANT EXECUTE ON FUNCTION public.initialize_new_user() TO PUBLIC;
GRANT EXECUTE ON FUNCTION public.can_read_list(lists) TO PUBLIC;
GRANT EXECUTE ON FUNCTION public.can_write_list(lists) TO PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_shared_list(text) TO PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_shared_list_records(text) TO PUBLIC;
GRANT EXECUTE ON FUNCTION public.compute_new_low() TO PUBLIC;
GRANT EXECUTE ON FUNCTION public.notification_audience_for_record(uuid) TO PUBLIC;
GRANT EXECUTE ON FUNCTION public.revoke_pending_invite(uuid) TO PUBLIC;
GRANT EXECUTE ON FUNCTION public.is_collection_member(uuid) TO PUBLIC;
GRANT EXECUTE ON FUNCTION public.is_collection_writer(uuid) TO PUBLIC;
GRANT EXECUTE ON FUNCTION public.is_collection_owner(uuid) TO PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_collection_member_profiles(uuid) TO PUBLIC;
GRANT EXECUTE ON FUNCTION public.normalized_artist_sort_name(text) TO PUBLIC;
GRANT EXECUTE ON FUNCTION public.stable_catalog_uuid(text) TO PUBLIC;
GRANT EXECUTE ON FUNCTION public.album_dedupe_key(text,text,integer) TO PUBLIC;
GRANT EXECUTE ON FUNCTION public.record_pressing_dedupe_key(uuid,integer,text,bigint,text) TO PUBLIC;
