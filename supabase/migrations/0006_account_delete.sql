-- Self-service account deletion. The function runs with service_role privileges
-- so it can call auth.admin.delete_user(...) for the calling user.

create or replace function public.delete_my_account()
returns void language plpgsql security definer set search_path = public, auth as $$
declare uid uuid := auth.uid();
begin
  if uid is null then
    raise exception 'not authenticated';
  end if;

  -- Cascading FKs handle records, price_entries, lists, list_items, list_members,
  -- device_tokens. We just need to remove the auth.users row.
  delete from auth.users where id = uid;
end;
$$;

revoke all on function public.delete_my_account() from public;
grant execute on function public.delete_my_account() to authenticated;
