create role anon nologin;
create role authenticated nologin;
create role service_role nologin;
create role deadwax_runtime nologin noinherit;
grant authenticated to deadwax_runtime;
