-- Device tokens for APNs.
-- A user can have multiple devices; we register one row per (user, device).

create table if not exists public.device_tokens (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  apns_token text not null,
  device_name text,
  bundle_id text not null,
  environment text not null check (environment in ('sandbox', 'production')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, apns_token)
);

create index if not exists device_tokens_user_idx on public.device_tokens (user_id);

drop trigger if exists device_tokens_touch_updated_at on public.device_tokens;
create trigger device_tokens_touch_updated_at
  before update on public.device_tokens
  for each row execute function public.touch_updated_at();

alter table public.device_tokens enable row level security;

drop policy if exists "device_tokens self" on public.device_tokens;
create policy "device_tokens self" on public.device_tokens
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

------------------------------------------------------------
-- Helper view: per-record min price so the edge function can detect new lows.
-- We materialise the previous-min as a column on price_entries so the edge
-- function only has to compare two cents values (previous_min vs new price).
------------------------------------------------------------
alter table public.price_entries
  add column if not exists previous_min_cents int,
  add column if not exists is_new_low boolean not null default false;

create or replace function public.compute_new_low()
returns trigger language plpgsql as $$
declare prev_min int;
begin
  select min(price_cents) into prev_min
  from public.price_entries
  where record_id = new.record_id and id <> new.id;

  new.previous_min_cents := prev_min;
  new.is_new_low := prev_min is null or new.price_cents < prev_min;
  return new;
end;
$$;

drop trigger if exists price_entries_compute_new_low on public.price_entries;
create trigger price_entries_compute_new_low
  before insert on public.price_entries
  for each row execute function public.compute_new_low();

------------------------------------------------------------
-- Helper RPC: who should be notified for a record?
-- Owner + every list member of any list containing this record.
-- Edge function calls this then fans out APNs pushes.
------------------------------------------------------------
create or replace function public.notification_audience_for_record(rid uuid)
returns table (user_id uuid)
language sql stable security definer set search_path = public as $$
  select r.owner_id
  from public.records r where r.id = rid and r.deleted_at is null
  union
  select m.user_id
  from public.list_items li
  join public.list_members m on m.list_id = li.list_id
  where li.record_id = rid;
$$;

grant execute on function public.notification_audience_for_record(uuid) to authenticated, service_role;
