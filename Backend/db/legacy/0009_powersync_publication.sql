-- PowerSync streams changes from Postgres via logical replication and
-- requires a publication named `powersync`. Supabase already has wal_level
-- = logical and the `postgres` role has REPLICATION, so creating the
-- publication is the only setup step.
--
-- If you add new synced tables in a later migration, add them here too
-- (or use ALTER PUBLICATION powersync ADD TABLE …).

drop publication if exists powersync;

create publication powersync for table
  public.profiles,
  public.records,
  public.price_entries,
  public.lists,
  public.list_items,
  public.list_members,
  public.pending_invites,
  public.device_tokens;
