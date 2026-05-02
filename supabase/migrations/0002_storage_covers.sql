-- Public bucket for cover art. Anyone authenticated can read; only the
-- owner can upload/update/delete files prefixed with their user id.

insert into storage.buckets (id, name, public)
values ('covers', 'covers', true)
on conflict (id) do update set public = true;

drop policy if exists "covers public read" on storage.objects;
create policy "covers public read" on storage.objects
  for select using (bucket_id = 'covers');

drop policy if exists "covers authenticated insert" on storage.objects;
create policy "covers authenticated insert" on storage.objects
  for insert with check (
    bucket_id = 'covers'
    and auth.role() = 'authenticated'
  );

drop policy if exists "covers authenticated update" on storage.objects;
create policy "covers authenticated update" on storage.objects
  for update using (
    bucket_id = 'covers' and auth.role() = 'authenticated'
  );
