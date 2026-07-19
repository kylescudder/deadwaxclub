------------------------------------------------------------
-- Restrict client writes to app-managed profile fields
------------------------------------------------------------

-- RLS still decides which profile row a user may write. Column privileges
-- decide which fields client roles may include in those writes.
revoke insert on public.profiles from anon, authenticated;
revoke update on public.profiles from anon, authenticated;

grant insert (id, display_name, primary_collection_id, created_at, updated_at)
  on public.profiles to authenticated;

grant update (display_name, primary_collection_id, updated_at)
  on public.profiles to authenticated;
