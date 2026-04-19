-- packages table: one row per uploaded mascot
create table if not exists public.packages (
  id            uuid primary key default gen_random_uuid(),
  name          text not null check (char_length(name) between 1 and 80),
  creator       text check (creator is null or char_length(creator) between 1 and 40),
  format        text not null check (format in ('snoroh', 'animime')),
  storage_path  text not null unique,
  size_bytes    integer not null check (size_bytes > 0),
  frame_counts  jsonb not null,
  preview_png   text not null,
  ip_hash       text not null,
  created_at    timestamptz not null default now()
);

create index if not exists packages_created_at_idx
  on public.packages (created_at desc);

create index if not exists packages_ip_hash_idx
  on public.packages (ip_hash, created_at desc);

alter table public.packages enable row level security;

-- Public can SELECT everything (gallery view is open).
create policy "packages_public_read"
  on public.packages for select
  using (true);

-- Anonymous clients cannot write directly; all writes go through the
-- service-role key used by the Next.js API routes.

-- Storage bucket for the blob files themselves (must be created via the
-- Supabase dashboard or CLI; this migration documents the expected config):
--
--   bucket name: packages
--   public: true
--   file size limit: 2 MiB
--   allowed mime types: application/json, application/octet-stream
