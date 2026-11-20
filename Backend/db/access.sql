grant usage on schema auth to authenticated;
-- Use an identity-filtered RLS policy for legacy invite lookups. Auth secrets
-- are in separate Better Auth tables and are inaccessible to authenticated.
alter table auth.users enable row level security;
create policy own_identity on auth.users for select to authenticated
using (id = auth.uid());
grant select (id, email) on auth.users to authenticated;

grant select on public.profiles, public.records, public.albums,
  public.record_pressings, public.price_entries, public.record_images,
  public.collections, public.notifications, public.lists, public.list_items,
  public.list_members, public.collection_members, public.pending_invites,
  public.collection_pending_invites to authenticated;

grant update (display_name, primary_collection_id) on public.profiles to authenticated;
grant update (read_at) on public.notifications to authenticated;
grant insert, update on public.albums, public.record_pressings, public.records,
  public.price_entries, public.record_images, public.collections, public.lists,
  public.list_items to authenticated;
grant delete on public.list_items, public.record_images,
  public.list_members, public.collection_members to authenticated;

create table public.native_codes (
  id text primary key,
  challenge text not null,
  session_token text not null,
  expires_at timestamptz not null
);
grant select, insert, delete on public.native_codes to deadwax_runtime;
grant select, insert, update on public.device_tokens to authenticated;
grant service_role, anon to deadwax_runtime;
grant usage on schema auth to service_role;

-- Initial membership is created atomically with a queued collection PUT.
create function public.initialize_collection_owner() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if auth.uid() is not null and new.created_by = auth.uid() then
    insert into public.collection_members (collection_id, user_id, role, invited_by)
      values (new.id, new.created_by, 'owner', new.created_by)
      on conflict (collection_id, user_id) do nothing;
  end if;
  return new;
end;
$$;
revoke all on function public.initialize_collection_owner() from public;
create trigger collections_initialize_owner after insert on public.collections
for each row execute function public.initialize_collection_owner();

create table public.cover_objects (
  path text primary key,
  pressing_id uuid not null,
  bytes bytea not null check (octet_length(bytes) between 3 and 5242880)
);
alter table public.cover_objects enable row level security;
create policy cover_read on public.cover_objects for select to anon, authenticated
using (true);
create policy cover_write on public.cover_objects for all to authenticated
using (exists (
  select 1 from public.records
  where record_pressing_id = cover_objects.pressing_id and deleted_at is null
    and public.is_collection_writer(collection_id)
))
with check (exists (
  select 1 from public.records
  where record_pressing_id = cover_objects.pressing_id and deleted_at is null
    and public.is_collection_writer(collection_id)
));
grant select on public.cover_objects to anon;
grant select, insert, update on public.cover_objects to authenticated;
