-- In-app notification inbox. Every push notification we send to a user is
-- *also* persisted as a row here so the iOS app's bell-icon tray has the same
-- history. The notify-inbox edge function fans an APNs push every time a row
-- is inserted (so anything that wants to notify a user just inserts a row).

create type public.notification_kind as enum ('price_alert', 'collection_invite');

create table if not exists public.notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  kind public.notification_kind not null,
  title text not null,
  body text not null,
  payload jsonb not null default '{}'::jsonb,
  read_at timestamptz,
  created_at timestamptz not null default now()
);

create index if not exists notifications_user_unread_idx
  on public.notifications (user_id, created_at desc)
  where read_at is null;

create index if not exists notifications_user_idx
  on public.notifications (user_id, created_at desc);

alter table public.notifications enable row level security;

drop policy if exists "notifications self" on public.notifications;
create policy "notifications self" on public.notifications
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

------------------------------------------------------------
-- Audience RPC for record-level events.
-- Now: every member of the record's collection + every member of any list
-- containing the record (so a collaborator on a list still gets pinged).
-- Replaces the records.owner_id-based version in 0005_notifications.sql.
------------------------------------------------------------
create or replace function public.notification_audience_for_record(rid uuid)
returns table (user_id uuid)
language sql stable security definer set search_path = public as $$
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

grant execute on function public.notification_audience_for_record(uuid) to authenticated, service_role;

------------------------------------------------------------
-- Re-create invite_to_collection to also write an inbox row when the invitee
-- already has an account. The notify-inbox webhook then fans an APNs push.
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
  v_collection_name text;
  v_inviter_name text;
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

  select c.name into v_collection_name
  from public.collections c
  where c.id = p_collection_id and c.deleted_at is null;

  if v_collection_name is null then
    raise exception 'collection not found';
  end if;

  select coalesce(p.display_name, 'Someone') into v_inviter_name
  from public.profiles p where p.id = auth.uid();

  select id into v_user_id from auth.users where lower(email) = lower(p_email) limit 1;

  if v_user_id is not null then
    insert into public.collection_members (collection_id, user_id, role, invited_by)
    values (p_collection_id, v_user_id, v_role, auth.uid())
    on conflict (collection_id, user_id) do update set role = excluded.role;

    insert into public.notifications (user_id, kind, title, body, payload)
    values (
      v_user_id,
      'collection_invite',
      v_collection_name,
      v_inviter_name || ' added you to this collection.',
      jsonb_build_object(
        'collection_id', p_collection_id,
        'inviter_id', auth.uid(),
        'inviter_name', v_inviter_name
      )
    );

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

------------------------------------------------------------
-- Refresh the PowerSync publication to include the new tables.
-- (Replaces 0009_powersync_publication.sql's table list.)
------------------------------------------------------------
drop publication if exists powersync;

create publication powersync for table
  public.profiles,
  public.records,
  public.price_entries,
  public.lists,
  public.list_items,
  public.list_members,
  public.pending_invites,
  public.device_tokens,
  public.collections,
  public.collection_members,
  public.collection_pending_invites,
  public.notifications;
