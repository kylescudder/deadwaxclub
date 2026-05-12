-- In-database triggers that POST to edge functions via pg_net, replacing the
-- Supabase Cloud "Database Webhooks" UI (which isn't available self-hosted).
--
-- The anon key is read from the database GUC `app.anon_key`, which is set by
-- the operator at install time:
--
--     ALTER DATABASE postgres SET app.anon_key = '<value from .env ANON_KEY>';
--
-- This keeps the secret out of the migration file so it can be committed.

create extension if not exists pg_net;

create or replace function public.call_edge_function(
  function_name text,
  payload jsonb
) returns void
language plpgsql
security definer
as $$
declare
  anon_key text;
begin
  anon_key := current_setting('app.anon_key', true);

  if anon_key is null or anon_key = '' then
    raise warning 'app.anon_key not set; edge function % was not called', function_name;
    return;
  end if;

  perform net.http_post(
    url := 'http://kong:8000/functions/v1/' || function_name,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || anon_key
    ),
    body := payload,
    timeout_milliseconds := 5000
  );
end;
$$;

create or replace function public.tg_notify_edge_function()
returns trigger
language plpgsql
security definer
as $$
declare
  function_name text;
  payload jsonb;
begin
  function_name := tg_argv[0];

  payload := jsonb_build_object(
    'type', tg_op,
    'table', tg_table_name,
    'schema', tg_table_schema,
    'record', to_jsonb(coalesce(new, old)),
    'old_record', case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) else null end
  );

  perform public.call_edge_function(function_name, payload);

  return coalesce(new, old);
end;
$$;

drop trigger if exists notifications_notify_inbox on public.notifications;
create trigger notifications_notify_inbox
  after insert on public.notifications
  for each row
  execute function public.tg_notify_edge_function('notify-inbox');

drop trigger if exists price_entries_notify_price_change on public.price_entries;
create trigger price_entries_notify_price_change
  after insert on public.price_entries
  for each row
  execute function public.tg_notify_edge_function('notify-price-change');
