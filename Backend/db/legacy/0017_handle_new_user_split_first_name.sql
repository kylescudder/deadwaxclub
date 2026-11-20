-- Supabase's GoTrue normalizer doesn't preserve the OIDC `given_name` /
-- `family_name` claims for Google in `raw_user_meta_data` — only `name` and
-- `full_name`. So 0016's `given_name` branch is always empty for Google sign-ins
-- and the trigger falls through to the full name.
--
-- Workaround: split the first whitespace-separated token off `name`/`full_name`
-- as a synthetic first-name. Users with one-word names ("Madonna") still get
-- the right value; users from cultures where surname-first is the convention
-- can edit it from Settings (this is the same trade-off most apps make).
--
-- Priority order:
--   1. `display_name`    — explicitly set in the manual signup form
--   2. `given_name`      — kept for providers that DO send it (Apple, etc.)
--   3. first word of `name`
--   4. first word of `full_name`
--   5. raw `name` / `full_name` (covers single-token names without a split)

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public, auth as $$
declare
  v_display_name text;
  v_personal_id uuid;
begin
  v_display_name := coalesce(
    nullif(new.raw_user_meta_data->>'display_name', ''),
    nullif(new.raw_user_meta_data->>'given_name', ''),
    nullif(split_part(new.raw_user_meta_data->>'name', ' ', 1), ''),
    nullif(split_part(new.raw_user_meta_data->>'full_name', ' ', 1), ''),
    nullif(new.raw_user_meta_data->>'name', ''),
    nullif(new.raw_user_meta_data->>'full_name', '')
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
