-- Return a usable member label even when profiles.display_name is empty.
-- Collection members can already see each other in the Members list; this
-- avoids falling back to UUID prefixes for users who have not set a profile
-- display name yet.

create or replace function public.get_collection_member_profiles(p_collection_id uuid)
returns table (
  id uuid,
  display_name text
)
language sql
stable
security definer
set search_path = public, auth
as $$
  select
    p.id,
    coalesce(
      nullif(btrim(p.display_name), ''),
      nullif(btrim(u.raw_user_meta_data->>'display_name'), ''),
      nullif(btrim(u.raw_user_meta_data->>'full_name'), ''),
      nullif(btrim(u.raw_user_meta_data->>'name'), ''),
      nullif(split_part(u.email, '@', 1), '')
    ) as display_name
  from public.collection_members cm
  join public.profiles p on p.id = cm.user_id
  join auth.users u on u.id = cm.user_id
  where cm.collection_id = p_collection_id
    and public.is_collection_member(p_collection_id)
  order by cm.joined_at asc;
$$;

grant execute on function public.get_collection_member_profiles(uuid) to authenticated;
