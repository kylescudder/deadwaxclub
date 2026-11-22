create table if not exists public.recovery_lease (
 id integer primary key, snapshot_started_at timestamptz not null,
 verified_at timestamptz not null, snapshot_id text not null
);
create or replace function public.require_recovery_lease() returns void
language plpgsql security definer set search_path = '' as $$
begin
  if clock_timestamp() - transaction_timestamp() >= interval '60 seconds'
     or not exists (
       select 1 from public.recovery_lease
       where id = 1
         and snapshot_started_at > clock_timestamp() - interval '600 seconds'
         and snapshot_started_at <= clock_timestamp()
         and verified_at >= snapshot_started_at
         and verified_at <= clock_timestamp()
         and length(snapshot_id) > 0
     ) then
    raise exception using errcode = 'DX006', message = 'Recovery proof unavailable; retry later';
  end if;
end $$;
revoke all on function public.require_recovery_lease() from public;


create or replace function public.guard_recoverable_mutation() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform public.require_recovery_lease();
  return null;
end $$;
revoke all on function public.guard_recoverable_mutation() from public;

