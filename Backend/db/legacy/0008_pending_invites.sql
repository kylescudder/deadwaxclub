-- Pending invites: lets a list owner invite someone by email even if they
-- don't have a Deadwax Club account yet. On signup, handle_new_user resolves
-- any pending invites matching the new user's email into list_members rows.

create table if not exists public.pending_invites (
  id uuid primary key default gen_random_uuid(),
  list_id uuid not null references public.lists(id) on delete cascade,
  email text not null,
  role list_member_role not null default 'viewer',
  invited_by uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  accepted_at timestamptz,
  unique (list_id, email)
);

create index if not exists pending_invites_email_idx
  on public.pending_invites (lower(email))
  where accepted_at is null;

------------------------------------------------------------
-- Replace handle_new_user to also auto-accept pending invites.
-- Existing trigger on auth.users (created in 0001_init.sql) will pick up
-- the new function definition.
------------------------------------------------------------
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public, auth as $$
begin
  insert into public.profiles (id, display_name)
  values (new.id, coalesce(new.raw_user_meta_data->>'display_name', split_part(new.email, '@', 1)))
  on conflict (id) do nothing;

  -- Promote any pending invites for this email to real list memberships.
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

------------------------------------------------------------
-- RPC: invite_to_list
-- Tries to find an existing user by email and adds them to list_members
-- directly. If no user exists, falls back to creating a pending_invites row.
-- Returns {"status": "added" | "pending"} so the client can show appropriate UI.
------------------------------------------------------------
create or replace function public.invite_to_list(
  p_list_id uuid,
  p_email text,
  p_role text
) returns json
language plpgsql security definer set search_path = public, auth as $$
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
  if v_list_owner <> auth.uid() then
    raise exception 'not authorized';
  end if;

  select id into v_user_id from auth.users where lower(email) = lower(p_email) limit 1;

  if v_user_id is not null then
    insert into public.list_members (list_id, user_id, role, invited_by)
    values (p_list_id, v_user_id, v_role, auth.uid())
    on conflict (list_id, user_id) do update set role = excluded.role;
    return json_build_object('status', 'added', 'user_id', v_user_id);
  else
    insert into public.pending_invites (list_id, email, role, invited_by)
    values (p_list_id, lower(p_email), v_role, auth.uid())
    on conflict (list_id, email) do update
      set role = excluded.role,
          accepted_at = null,
          created_at = now();
    return json_build_object('status', 'pending');
  end if;
end;
$$;

revoke all on function public.invite_to_list(uuid, text, text) from public;
grant execute on function public.invite_to_list(uuid, text, text) to authenticated;

------------------------------------------------------------
-- RLS for pending_invites
------------------------------------------------------------
alter table public.pending_invites enable row level security;

drop policy if exists "pending_invites owner all" on public.pending_invites;
create policy "pending_invites owner all" on public.pending_invites
  for all using (
    exists (select 1 from public.lists l
            where l.id = list_id and l.owner_id = auth.uid())
  ) with check (
    exists (select 1 from public.lists l
            where l.id = list_id and l.owner_id = auth.uid())
  );

-- Invitee (once authenticated with the matching email) can read their own pending row.
drop policy if exists "pending_invites by email" on public.pending_invites;
create policy "pending_invites by email" on public.pending_invites
  for select using (
    lower(email) = lower((select email from auth.users where id = auth.uid()))
  );

------------------------------------------------------------
-- Convenience: revoke an outstanding invite (delete by id, owner-only via RLS).
------------------------------------------------------------
create or replace function public.revoke_pending_invite(p_invite_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  delete from public.pending_invites pi
  using public.lists l
  where pi.id = p_invite_id
    and pi.list_id = l.id
    and l.owner_id = auth.uid();
end;
$$;

grant execute on function public.revoke_pending_invite(uuid) to authenticated;
