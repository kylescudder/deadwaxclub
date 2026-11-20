-- Pull the user's display name from the OAuth provider when available, instead
-- of falling back to the email's local-part (which produces ugly handles like
-- "scud1997" for "scud1997@gmail.com").
--
-- Provider field reference:
--   * Email/password (manual signup): we set `raw_user_meta_data.display_name`
--     in the iOS client.
--   * Google OAuth: Supabase exposes `full_name`, `name`, `given_name`,
--     `family_name`, `picture` on raw_user_meta_data.
--   * Sign in with Apple: Apple only returns the name on the very first sign-in,
--     so the iOS client also writes it via REST after a successful Apple sign-in.
--     This trigger preserves whatever the iOS client sets.
--
-- If none of the OAuth fields are present we leave display_name NULL — the user
-- can set it later from Settings, and the iOS app surfaces a "Not set" state.

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public, auth as $$
declare
  v_display_name text;
  v_personal_id uuid;
begin
  v_display_name := coalesce(
    nullif(new.raw_user_meta_data->>'display_name', ''),
    nullif(new.raw_user_meta_data->>'full_name', ''),
    nullif(new.raw_user_meta_data->>'name', ''),
    nullif(new.raw_user_meta_data->>'given_name', '')
  );

  insert into public.profiles (id, display_name)
  values (new.id, v_display_name)
  on conflict (id) do nothing;

  -- Mint a personal collection unless one is already pointed to (idempotent re-trigger).
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

  -- Promote any pending list invites for this email.
  insert into public.list_members (list_id, user_id, role, invited_by)
  select pi.list_id, new.id, pi.role, pi.invited_by
  from public.pending_invites pi
  where lower(pi.email) = lower(new.email)
    and pi.accepted_at is null
  on conflict (list_id, user_id) do nothing;

  update public.pending_invites
  set accepted_at = now()
  where lower(email) = lower(new.email) and accepted_at is null;

  -- Promote any pending collection invites for this email.
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
