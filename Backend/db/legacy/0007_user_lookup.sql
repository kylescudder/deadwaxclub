-- Look up a user_id by email so the inviter can add them to a list.
-- Stays in security definer because auth.users isn't readable from RLS.
create or replace function public.lookup_user_id_by_email(email_in text)
returns table (user_id uuid)
language sql stable security definer set search_path = public, auth as $$
  select id from auth.users where lower(email) = lower(email_in) limit 1;
$$;

revoke all on function public.lookup_user_id_by_email(text) from public;
grant execute on function public.lookup_user_id_by_email(text) to authenticated;
