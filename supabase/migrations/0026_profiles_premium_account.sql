------------------------------------------------------------
-- Manual premium account override
------------------------------------------------------------

alter table public.profiles
  add column if not exists is_premium_account boolean not null default false;

-- Keep the premium override server/admin-managed. The existing RLS policy lets
-- users update their own profile row, so narrow client column privileges to the
-- fields the app is expected to write.
revoke insert on public.profiles from anon, authenticated;
revoke update on public.profiles from anon, authenticated;

grant insert (id, display_name, primary_collection_id, created_at, updated_at)
  on public.profiles to authenticated;
grant update (display_name, primary_collection_id, updated_at)
  on public.profiles to authenticated;

drop publication if exists powersync;

create publication powersync for table
  public.profiles,
  public.records,
  public.albums,
  public.record_pressings,
  public.price_entries,
  public.lists,
  public.list_items,
  public.list_members,
  public.pending_invites,
  public.device_tokens,
  public.collections,
  public.collection_members,
  public.collection_pending_invites,
  public.notifications,
  public.record_images,
  public.iap_entitlements;
