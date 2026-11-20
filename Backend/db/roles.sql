-- Compatibility for local fixtures only. Production uses the common provisioner.
-- Never create or alter generic Supabase roles on Herman's shared server.
do $$ begin
  if not exists(select 1 from pg_roles where rolname='deadwax_api') then create role deadwax_api nologin; end if;
  if not exists(select 1 from pg_roles where rolname='deadwax_anon') then create role deadwax_anon nologin; end if;
  if not exists(select 1 from pg_roles where rolname='deadwax_service') then create role deadwax_service nologin; end if;
  if not exists(select 1 from pg_roles where rolname='deadwax_runtime') then create role deadwax_runtime nologin noinherit; end if;
  if not exists(select 1 from pg_roles where rolname='deadwaxclub_recovery') then create role deadwaxclub_recovery nologin; end if;
end $$;
grant deadwax_api,deadwax_anon,deadwax_service to deadwax_runtime;
