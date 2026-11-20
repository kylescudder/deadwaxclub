-- Collection invite RPCs + extend handle_new_user to also mint a personal
-- collection on signup and resolve any matching collection_pending_invites.

------------------------------------------------------------
-- handle_new_user: profile + personal collection + resolve pending invites
-- (lists *and* collections).
------------------------------------------------------------
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public, auth as $$
declare
  v_display_name text;
  v_personal_id uuid;
begin
  v_display_name := coalesce(new.raw_user_meta_data->>'display_name', split_part(new.email, '@', 1));

  insert into public.profiles (id, display_name)
  values (new.id, v_display_name)
  on conflict (id) do nothing;

  -- Mint a personal collection unless one is already pointed to (idempotent re-trigger).
  if (select primary_collection_id from public.profiles where id = new.id) is null then
    insert into public.collections (name, created_by)
    values (coalesce(v_display_name || '''s Collection', 'My Collection'), new.id)
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

------------------------------------------------------------
-- invite_to_collection
-- Looks up a user by email; if found, inserts into collection_members.
-- Otherwise stores a row in collection_pending_invites that resolves on signup.
-- Returns {"status": "added" | "pending"}.
-- Mirrors invite_to_list (0008_pending_invites.sql).
------------------------------------------------------------
create or replace function public.invite_to_collection(
  p_collection_id uuid,
  p_email text,
  p_role text
) returns json
language plpgsql security definer set search_path = public, auth as $$
declare
  v_user_id uuid;
  v_role public.collection_member_role := p_role::public.collection_member_role;
begin
  if p_email is null or trim(p_email) = '' then
    raise exception 'email required';
  end if;

  if not exists (
    select 1 from public.collection_members m
    where m.collection_id = p_collection_id
      and m.user_id = auth.uid()
      and m.role = 'owner'
  ) then
    raise exception 'not authorized';
  end if;

  if not exists (
    select 1 from public.collections c
    where c.id = p_collection_id and c.deleted_at is null
  ) then
    raise exception 'collection not found';
  end if;

  select id into v_user_id from auth.users where lower(email) = lower(p_email) limit 1;

  if v_user_id is not null then
    insert into public.collection_members (collection_id, user_id, role, invited_by)
    values (p_collection_id, v_user_id, v_role, auth.uid())
    on conflict (collection_id, user_id) do update set role = excluded.role;
    return json_build_object('status', 'added', 'user_id', v_user_id);
  else
    insert into public.collection_pending_invites (collection_id, email, role, invited_by)
    values (p_collection_id, lower(p_email), v_role, auth.uid())
    on conflict (collection_id, email) do update
      set role = excluded.role,
          accepted_at = null,
          created_at = now();
    return json_build_object('status', 'pending');
  end if;
end;
$$;

revoke all on function public.invite_to_collection(uuid, text, text) from public;
grant execute on function public.invite_to_collection(uuid, text, text) to authenticated;

------------------------------------------------------------
-- revoke_collection_invite
------------------------------------------------------------
create or replace function public.revoke_collection_invite(p_invite_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  delete from public.collection_pending_invites cpi
  using public.collection_members m
  where cpi.id = p_invite_id
    and m.collection_id = cpi.collection_id
    and m.user_id = auth.uid()
    and m.role = 'owner';
end;
$$;

revoke all on function public.revoke_collection_invite(uuid) from public;
grant execute on function public.revoke_collection_invite(uuid) to authenticated;
