-- DESTRUCTIVE — wipes every user and every row of user data from this project,
-- plus every cover-art object in Supabase Storage.
-- Intended for development resets only. NEVER run against a production project.
--
-- Run via Supabase Studio → SQL editor (one-shot) or:
--   psql "$SUPABASE_DB_URL" -f Supabase/scripts/purge-all.sql
--
-- What this clears:
--   * auth.users (which cascades to profiles, which cascades to records,
--     price_entries, record_images, lists, list_items, list_members,
--     pending_invites, collections, collection_members,
--     collection_pending_invites, notifications, device_tokens — all
--     configured `on delete cascade`)
--
-- Storage objects in the `covers` bucket are NOT cleared by this script —
-- `storage.objects` is owned by `supabase_storage_admin` so the postgres
-- role can't ALTER it to bypass the protect_delete trigger. To clear the
-- bucket too, run from the repo root:
--
--   ./Supabase/scripts/purge-storage.sh
--
-- (or Studio → Storage → covers → select-all → delete for a one-off.)
--
-- What this does NOT touch:
--   * Schema / migrations (use `supabase db reset` if you want to drop tables)
--   * Edge function secrets / project settings
--   * The PowerSync replication slot (PowerSync handles the empty-state cleanly)

begin;

-- Auth + cascade-wipe the public schema.
delete from auth.users;

commit;

-- Sanity check — every count below should be zero.
select 'auth.users' as table_name, count(*) from auth.users
union all select 'profiles', count(*) from public.profiles
union all select 'records', count(*) from public.records
union all select 'record_images', count(*) from public.record_images
union all select 'price_entries', count(*) from public.price_entries
union all select 'collections', count(*) from public.collections
union all select 'collection_members', count(*) from public.collection_members
union all select 'collection_pending_invites', count(*) from public.collection_pending_invites
union all select 'lists', count(*) from public.lists
union all select 'list_items', count(*) from public.list_items
union all select 'list_members', count(*) from public.list_members
union all select 'pending_invites', count(*) from public.pending_invites
union all select 'notifications', count(*) from public.notifications
union all select 'device_tokens', count(*) from public.device_tokens;
