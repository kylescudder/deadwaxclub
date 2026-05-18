-- Expose display names for members of a Collection without making all
-- profiles globally readable. The caller must already belong to the Collection.

create or replace function public.get_collection_member_profiles(p_collection_id uuid)
returns table (
  id uuid,
  display_name text
)
language sql
stable
security definer
set search_path = public
as $$
  select p.id, p.display_name
  from public.collection_members cm
  join public.profiles p on p.id = cm.user_id
  where cm.collection_id = p_collection_id
    and public.is_collection_member(p_collection_id)
  order by cm.joined_at asc;
$$;

grant execute on function public.get_collection_member_profiles(uuid) to authenticated;
