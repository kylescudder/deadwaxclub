-- Collection invites wait for the invitee. Inviting never adds anyone
-- directly: every invite is pending, the API emails the invitee (and an
-- existing account also gets an inbox notification), and they accept or
-- decline it in the app while signed in with a verified account for that
-- email address. Signing up no longer joins pending Collections.
--
-- Errors: DW004 (invalid invite, 422) and DW005 (not the owner, 403) carry
-- messages the app shows as they are.

create or replace function public.collection_invite_display_name(p_user_id uuid) returns text
    language sql stable security definer
    set search_path to ''
    as $$
  select coalesce(
    nullif(btrim(p.display_name), ''),
    nullif(btrim(u.metadata->>'display_name'), ''),
    nullif(btrim(u.metadata->>'full_name'), ''),
    nullif(btrim(u.metadata->>'name'), ''),
    nullif(split_part(u.email, '@', 1), ''),
    'Someone'
  )
  from identity.users u
  left join public.profiles p on p.id = u.id
  where u.id = p_user_id
$$;
revoke all on function public.collection_invite_display_name(uuid) from public;

-- Returns the details the API needs to email the invitee; the API sends the
-- app only `status`.
create or replace function public.invite_to_collection(p_collection_id uuid, p_email text, p_role text) returns json
    language plpgsql security definer
    set search_path to ''
    as $$
declare
  me uuid := identity.user_id();
  v_email text := lower(btrim(coalesce(p_email, '')));
  v_user_id uuid;
  v_collection_name text;
  v_inviter_name text;
  v_invite_id uuid;
begin
  if me is null or not exists (
    select 1 from public.collection_members m
    where m.collection_id = p_collection_id and m.user_id = me and m.role = 'owner'
  ) then
    raise exception using errcode = 'DW005', message = 'Only the Collection''s owner can invite people.';
  end if;
  select c.name into v_collection_name
  from public.collections c
  where c.id = p_collection_id and c.deleted_at is null;
  if v_collection_name is null then
    raise exception using errcode = 'DW004', message = 'This Collection no longer exists.';
  end if;
  if p_role is null or p_role not in ('editor', 'viewer') then
    raise exception using errcode = 'DW004', message = 'Choose Editor or Viewer.';
  end if;
  if length(v_email) > 320 or v_email !~ '^[^@[:space:]]+@[^@[:space:]]+$' then
    raise exception using errcode = 'DW004', message = 'Enter the email address they use to sign in.';
  end if;

  select u.id into v_user_id from identity.users u where lower(u.email) = v_email limit 1;
  if v_user_id = me then
    raise exception using errcode = 'DW004', message = 'That''s your own email address.';
  end if;
  if v_user_id is not null and exists (
    select 1 from public.collection_members m
    where m.collection_id = p_collection_id and m.user_id = v_user_id
  ) then
    raise exception using errcode = 'DW004', message = 'They already have access.';
  end if;
  -- Limits invite rows. Revoking deletes rows, so this is not what bounds
  -- email: the API's email sender caps each account's invite mail in
  -- auth_email_limit, which revoking or re-sending can't reset.
  if (
    select count(*) from public.collection_pending_invites
    where invited_by = me and created_at > statement_timestamp() - interval '1 day'
  ) >= 50 then
    raise exception using errcode = 'DW004', message = 'You''ve sent a lot of invites today. Try again tomorrow.';
  end if;

  insert into public.collection_pending_invites (collection_id, email, role, invited_by)
  values (p_collection_id, v_email, p_role::public.collection_member_role, me)
  on conflict (collection_id, email) do update
    set role = excluded.role, invited_by = excluded.invited_by,
        accepted_at = null, created_at = statement_timestamp()
  returning id into v_invite_id;

  v_inviter_name := public.collection_invite_display_name(me);
  if v_user_id is not null then
    insert into public.notifications (user_id, kind, title, body, payload)
    values (
      v_user_id,
      'collection_invite',
      v_collection_name,
      v_inviter_name || ' invited you to this Collection.',
      jsonb_build_object(
        'collection_id', p_collection_id,
        'invite_id', v_invite_id,
        'inviter_id', me,
        'inviter_name', v_inviter_name
      )
    );
  end if;

  return json_build_object(
    'status', 'pending',
    'email', v_email,
    'inviter', v_inviter_name,
    'target', 'the Collection “' || v_collection_name || '”'
  );
end;
$$;

-- Open Collection invites sent to the caller's verified email.
create or replace function public.get_incoming_collection_invites()
returns table (id uuid, space_id uuid, space_name text, inviter_name text, role text, created_at timestamptz)
    language sql stable security definer
    set search_path to ''
    as $$
  select i.id, i.collection_id, c.name, public.collection_invite_display_name(i.invited_by),
         i.role::text, i.created_at
  from public.collection_pending_invites i
  join public.collections c on c.id = i.collection_id and c.deleted_at is null
  join identity.users me on me.id = identity.user_id()
  where i.email = lower(me.email) and i.accepted_at is null
  order by i.created_at desc
$$;
revoke all on function public.get_incoming_collection_invites() from public;

create or replace function public.accept_collection_invite(p_invite_id uuid) returns json
    language plpgsql security definer
    set search_path to ''
    as $$
declare
  me uuid := identity.user_id();
  v_collection_id uuid;
  v_role public.collection_member_role;
  v_inviter uuid;
begin
  select i.collection_id, i.role, i.invited_by into v_collection_id, v_role, v_inviter
  from public.collection_pending_invites i
  join public.collections c on c.id = i.collection_id and c.deleted_at is null
  join identity.users u on u.id = me
  where i.id = p_invite_id and i.email = lower(u.email) and i.accepted_at is null
  for update of i;
  if v_collection_id is null then
    raise exception using errcode = 'DW004', message = 'This invite is no longer available.';
  end if;

  insert into public.collection_members (collection_id, user_id, role, invited_by)
  values (v_collection_id, me, v_role, v_inviter)
  on conflict (collection_id, user_id) do update set role = excluded.role
  where public.collection_members.role <> 'owner';
  update public.collection_pending_invites set accepted_at = statement_timestamp()
  where id = p_invite_id;
  return json_build_object('status', 'accepted', 'space_id', v_collection_id);
end;
$$;
revoke all on function public.accept_collection_invite(uuid) from public;

create or replace function public.decline_collection_invite(p_invite_id uuid) returns void
    language sql security definer
    set search_path to ''
    as $$
  delete from public.collection_pending_invites i
  using identity.users u
  where u.id = identity.user_id()
    and i.id = p_invite_id and i.email = lower(u.email) and i.accepted_at is null
$$;
revoke all on function public.decline_collection_invite(uuid) from public;

grant execute on function
  public.get_incoming_collection_invites(),
  public.accept_collection_invite(uuid),
  public.decline_collection_invite(uuid)
to deadwax_api;

-- Signing up still creates the personal Collection and still accepts List
-- invites; Collection invites now wait to be accepted.
create or replace function public.initialize_new_user() returns trigger
    language plpgsql security definer
    set search_path to 'public', 'auth'
    as $$
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

  return new;
end;
$$;
