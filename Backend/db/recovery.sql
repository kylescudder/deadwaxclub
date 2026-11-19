CREATE TABLE "recovery_lease" (
	"id" integer PRIMARY KEY NOT NULL,
	"snapshot_started_at" timestamp with time zone NOT NULL,
	"verified_at" timestamp with time zone NOT NULL,
	"snapshot_id" text NOT NULL
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
grant execute on function public.require_recovery_lease() to authenticated, deadwax_runtime;
create or replace function public.guard_recoverable_mutation() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform public.require_recovery_lease();
  return null;
end $$;
revoke all on function public.guard_recoverable_mutation() from public;

do $$
declare table_name text;
begin
  foreach table_name in array array[
    'auth_user', 'auth_account', 'auth_session', 'auth_verification',
    'auth_rate_limit', 'auth_email_limit', 'auth_jwks', 'profiles',
    'records', 'albums', 'record_pressings', 'price_entries', 'record_images',
    'collections', 'collection_members', 'collection_pending_invites',
    'lists', 'list_items', 'list_members', 'pending_invites', 'notifications',
    'record_creation_events', 'record_creation_quotas', 'device_tokens',
    'iap_entitlements', 'native_codes', 'cover_objects'
  ] loop
    execute format('create trigger recovery_before before insert or update or delete on public.%I for each statement execute function public.guard_recoverable_mutation()', table_name);
    execute format('create constraint trigger recovery_commit after insert or update or delete on public.%I deferrable initially deferred for each row execute function public.guard_recoverable_mutation()', table_name);
  end loop;
end $$;

grant select, insert, update, delete on public.auth_user, public.auth_account,
  public.auth_session, public.auth_verification, public.auth_rate_limit,
  public.auth_email_limit, public.auth_jwks to deadwax_runtime;
