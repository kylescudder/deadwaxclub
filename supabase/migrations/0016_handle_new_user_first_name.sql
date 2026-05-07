-- Prefer the first-name only when seeding `display_name` from an OAuth
-- provider's payload. "Kyle" reads better than "Kyle Scudder" as a casual
-- in-app handle, and the user can flip to whatever they want from Settings.
--
-- Priority order:
--   1. `display_name`  — explicitly set in the manual signup form
--   2. `given_name`    — Google / Apple first-name field (preferred)
--   3. `name`          — full name fallback (some providers only send this)
--   4. `full_name`     — alternate full-name field
--
-- If none are present, leave NULL — Settings shows "Not set".

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public, auth as $$
declare
  v_display_name text;
  v_personal_id uuid;
begin
  v_display_name := coalesce(
    nullif(new.raw_user_meta_data->>'display_name', ''),
    nullif(new.raw_user_meta_data->>'given_name', ''),
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
