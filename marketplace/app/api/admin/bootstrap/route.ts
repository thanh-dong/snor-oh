// Supabase's direct (non-pooling) Postgres endpoint serves a cert chain
// Node's default trust store doesn't accept. rejectUnauthorized: false on
// pg's ssl option isn't reliably honored when connectionString carries
// its own sslmode, so force-disable validation at the Node TLS layer.
// Scoped to this one serverless function invocation.
process.env.NODE_TLS_REJECT_UNAUTHORIZED = "0";

import { NextResponse } from "next/server";
import { Client } from "pg";
import { supabaseService, BUCKET } from "@/lib/supabase";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";
export const maxDuration = 30;

const MIGRATION_SQL = `
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

do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'packages'
      and policyname = 'packages_public_read'
  ) then
    create policy "packages_public_read"
      on public.packages for select
      using (true);
  end if;
end
$$;

-- Tell PostgREST to reload its schema cache so freshly-created tables
-- become visible to the REST API immediately.
notify pgrst, 'reload schema';
`;

function authorized(req: Request): boolean {
  const token = process.env.ADMIN_TOKEN;
  if (!token || token === "changeme") return false;
  const header = req.headers.get("authorization") ?? "";
  const [scheme, value] = header.split(" ", 2);
  return scheme === "Bearer" && value === token;
}

function postgresUrl(): string | undefined {
  return (
    process.env.POSTGRES_URL_NON_POOLING ??
    process.env.POSTGRES_URL ??
    process.env.DATABASE_URL ??
    process.env.snoroh_POSTGRES_URL_NON_POOLING ??
    process.env.snoroh_POSTGRES_URL
  );
}

interface StepResult {
  ok: boolean;
  note?: string;
  error?: string;
}

async function runMigration(): Promise<StepResult> {
  const url = postgresUrl();
  if (!url) {
    return { ok: false, error: "No POSTGRES_URL_NON_POOLING / POSTGRES_URL / DATABASE_URL in env" };
  }
  const client = new Client({
    connectionString: url,
    ssl: { rejectUnauthorized: false },
  });
  try {
    await client.connect();
    await client.query(MIGRATION_SQL);
    return { ok: true, note: "packages table + indexes + RLS policy applied (idempotent)" };
  } catch (e) {
    return { ok: false, error: e instanceof Error ? e.message : String(e) };
  } finally {
    try { await client.end(); } catch { /* noop */ }
  }
}

async function ensureBucket(): Promise<StepResult> {
  try {
    const db = supabaseService();
    const existing = await db.storage.getBucket(BUCKET);
    if (existing.data) {
      return { ok: true, note: `bucket "${BUCKET}" already exists` };
    }
    const { error } = await db.storage.createBucket(BUCKET, {
      public: true,
      fileSizeLimit: 2 * 1024 * 1024,
      allowedMimeTypes: ["application/json", "application/octet-stream"],
    });
    if (error) return { ok: false, error: error.message };
    return { ok: true, note: `bucket "${BUCKET}" created` };
  } catch (e) {
    return { ok: false, error: e instanceof Error ? e.message : String(e) };
  }
}

export async function POST(req: Request) {
  if (!authorized(req)) {
    return NextResponse.json(
      { error: { code: "unauthorized", message: "Set ADMIN_TOKEN env var and pass it as Bearer token" } },
      { status: 401 }
    );
  }

  const migration = await runMigration();
  const bucket = await ensureBucket();

  return NextResponse.json(
    { ok: migration.ok && bucket.ok, migration, bucket },
    { status: migration.ok && bucket.ok ? 200 : 500 }
  );
}
