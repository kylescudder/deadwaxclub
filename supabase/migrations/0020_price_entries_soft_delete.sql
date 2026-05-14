-- Soft-delete support for price_entries.
--
-- Brings price_entries in line with the project-wide convention: deletions
-- are recorded as a `deleted_at` timestamp rather than DELETE statements so
-- PowerSync propagates tombstones to offline clients. Without this, a device
-- offline at the moment of deletion could miss the DELETE and end up with an
-- orphan local row.

alter table public.price_entries
  add column if not exists updated_at timestamptz not null default now(),
  add column if not exists deleted_at timestamptz;

-- Existing rows: backfill updated_at to created_at so ordering by
-- updated_at desc keeps the same shape as scanned_at desc.
update public.price_entries
set updated_at = created_at
where updated_at is null or updated_at = created_at;

drop trigger if exists price_entries_touch_updated_at on public.price_entries;
create trigger price_entries_touch_updated_at
  before update on public.price_entries
  for each row execute function public.touch_updated_at();

-- compute_new_low must ignore soft-deleted entries; otherwise an old "low"
-- that the user has since deleted would still suppress the is_new_low flag
-- on a fresh scan.
create or replace function public.compute_new_low()
returns trigger language plpgsql as $$
declare prev_min int;
begin
  select min(price_cents) into prev_min
  from public.price_entries
  where record_id = new.record_id
    and id <> new.id
    and deleted_at is null;

  new.previous_min_cents := prev_min;
  new.is_new_low := prev_min is null or new.price_cents < prev_min;
  return new;
end;
$$;
