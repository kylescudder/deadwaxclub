-- The PowerSync CRUD upload performs `.upsert()` (INSERT ... ON CONFLICT DO
-- UPDATE) for every PUT entry. Postgres RLS evaluates the INSERT check
-- even when the conflict path is hit, so without an INSERT policy the
-- upload is rejected with 42501 — and because the CRUD queue is FIFO,
-- a stuck profiles upload blocks every subsequent record/list upload.
--
-- The original profile row is created server-side by handle_new_user()
-- under security definer, but the client must also be able to write its
-- own row to satisfy the upsert path.

drop policy if exists "profiles insert own" on public.profiles;
create policy "profiles insert own" on public.profiles
  for insert with check (id = auth.uid());
