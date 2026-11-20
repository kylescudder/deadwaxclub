-- Estimated price + Discogs metadata refresh.
-- Stored in cents to keep arithmetic clean; null means "not looked up yet".

alter table public.records
  add column if not exists estimated_price_cents int,
  add column if not exists estimated_price_currency text default 'GBP',
  add column if not exists estimated_price_updated_at timestamptz;

create index if not exists records_owner_status_updated_idx
  on public.records (owner_id, status, updated_at desc)
  where deleted_at is null;
