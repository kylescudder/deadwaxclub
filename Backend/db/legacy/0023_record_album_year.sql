-- Store the original album/master year separately from the specific
-- Discogs release year. For represses, `records.year` remains the pressing /
-- release year while `album_year` can hold the original album year.

alter table public.records
  add column if not exists album_year int;
