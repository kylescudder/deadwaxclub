------------------------------------------------------------
-- Manual premium account override
------------------------------------------------------------

alter table public.profiles
  add column if not exists is_premium_account boolean not null default false;

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
