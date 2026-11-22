------------------------------------------------------------
-- Creator-scoped record limits + StoreKit entitlement mirror
------------------------------------------------------------

alter table public.records
  add column if not exists created_by uuid references public.profiles(id) on delete set null;

with collection_owners as (
  select distinct on (collection_id)
    collection_id,
    user_id
  from public.collection_members
  where role = 'owner'
  order by collection_id, joined_at asc
)
update public.records r
set created_by = co.user_id
from collection_owners co
where r.created_by is null
  and r.collection_id = co.collection_id;

create index if not exists records_created_by_idx
  on public.records (created_by)
  where deleted_at is null;

create table if not exists public.iap_entitlements (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  product_id text not null,
  original_transaction_id text,
  status text not null check (status in ('active', 'expired', 'revoked', 'unknown')),
  expires_at timestamptz,
  revoked_at timestamptz,
  environment text,
  updated_at timestamptz not null default now()
);

create index if not exists iap_entitlements_status_idx
  on public.iap_entitlements (status, expires_at);

drop trigger if exists iap_entitlements_touch_updated_at on public.iap_entitlements;
create trigger iap_entitlements_touch_updated_at
  before update on public.iap_entitlements
  for each row execute function public.touch_updated_at();

alter table public.iap_entitlements enable row level security;

drop policy if exists "iap_entitlements read own" on public.iap_entitlements;
create policy "iap_entitlements read own" on public.iap_entitlements
  for select using (user_id = auth.uid());

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
