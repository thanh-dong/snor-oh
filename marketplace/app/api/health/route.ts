import { NextResponse } from "next/server";
import { supabaseService, BUCKET } from "@/lib/supabase";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const REDIS_VARS = [
  "snoroh_REDIS_URL",
  "REDIS_URL",
  "UPSTASH_REDIS_URL",
];

const SUPABASE_VARS = [
  "NEXT_PUBLIC_SUPABASE_URL",
  "NEXT_PUBLIC_SUPABASE_ANON_KEY",
  "SUPABASE_URL",
  "SUPABASE_ANON_KEY",
  "SUPABASE_SERVICE_ROLE_KEY",
  "snoroh_SUPABASE_URL",
  "snoroh_SUPABASE_ANON_KEY",
  "snoroh_SUPABASE_SERVICE_ROLE_KEY",
  "snoroh_POSTGRES_URL_NON_POOLING",
];

const OTHER_VARS = ["ADMIN_TOKEN", "IP_HASH_SALT"];

function presence(names: string[]): Record<string, boolean> {
  const out: Record<string, boolean> = {};
  for (const n of names) out[n] = !!process.env[n];
  return out;
}

export async function GET() {
  const env = {
    supabase: presence(SUPABASE_VARS),
    redis: presence(REDIS_VARS),
    other: presence(OTHER_VARS),
  };

  let tableOk = false;
  let tableError: string | null = null;
  let bucketOk = false;
  let bucketError: string | null = null;

  try {
    const db = supabaseService();
    const { error } = await db.from("packages").select("id", { head: true, count: "exact" });
    if (error) tableError = error.message;
    else tableOk = true;
  } catch (e) {
    tableError = e instanceof Error ? e.message : String(e);
  }

  try {
    const db = supabaseService();
    const { data, error } = await db.storage.getBucket(BUCKET);
    if (error) bucketError = error.message;
    else if (data) bucketOk = true;
  } catch (e) {
    bucketError = e instanceof Error ? e.message : String(e);
  }

  const ready = tableOk && bucketOk &&
    (env.redis.snoroh_REDIS_URL || env.redis.REDIS_URL || env.redis.UPSTASH_REDIS_URL) &&
    (env.supabase.NEXT_PUBLIC_SUPABASE_URL || env.supabase.SUPABASE_URL || env.supabase.snoroh_SUPABASE_URL) &&
    (env.supabase.SUPABASE_SERVICE_ROLE_KEY || env.supabase.snoroh_SUPABASE_SERVICE_ROLE_KEY);

  return NextResponse.json({
    ready,
    env,
    supabase: {
      packages_table: tableOk,
      packages_table_error: tableError,
      packages_bucket: bucketOk,
      packages_bucket_error: bucketError,
    },
  });
}
