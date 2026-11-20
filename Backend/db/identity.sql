-- Stable, application-owned identity projection for existing Deadwax foreign
-- keys and row policies. Passwords, sessions, and OAuth identities are stored
-- exclusively by Better Auth.
create schema auth;

create table auth.users (
  id uuid primary key references public.auth_user(id) on delete cascade,
  email text not null,
  raw_user_meta_data jsonb not null default '{}'
);

create function auth.uid() returns uuid
language sql stable
as $$
  select nullif(current_setting('deadwax.user_id', true), '')::uuid
$$;

create function auth.role() returns text
language sql stable
as $$
  select coalesce(nullif(current_setting('role', true), 'none'), 'anon')
$$;

create function auth.sync_verified_identity() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if new.email_verified then
    insert into auth.users (id, email, raw_user_meta_data)
      values (new.id, new.email, jsonb_build_object('display_name', new.name))
      on conflict (id) do update set email = excluded.email;
  end if;
  return new;
end;
$$;

create trigger sync_verified_identity
after insert or update of email_verified, email on public.auth_user
for each row execute function auth.sync_verified_identity();
