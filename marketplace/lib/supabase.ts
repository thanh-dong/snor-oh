import { createClient, type SupabaseClient } from "@supabase/supabase-js";

export const BUCKET = "packages";

let _service: SupabaseClient | null = null;
let _anon: SupabaseClient | null = null;

function supabaseUrl(): string | undefined {
  return (
    process.env.NEXT_PUBLIC_SUPABASE_URL ??
    process.env.SUPABASE_URL ??
    process.env.NEXT_PUBLIC_snoroh_SUPABASE_URL ??
    process.env.snoroh_SUPABASE_URL
  );
}

function anonKey(): string | undefined {
  return (
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY ??
    process.env.SUPABASE_ANON_KEY ??
    process.env.NEXT_PUBLIC_snoroh_SUPABASE_ANON_KEY ??
    process.env.snoroh_SUPABASE_ANON_KEY
  );
}

function serviceKey(): string | undefined {
  return (
    process.env.SUPABASE_SERVICE_ROLE_KEY ??
    process.env.snoroh_SUPABASE_SERVICE_ROLE_KEY
  );
}

export function supabaseService(): SupabaseClient {
  if (_service) return _service;
  const url = supabaseUrl();
  const key = serviceKey();
  if (!url || !key) throw new Error("Supabase service env vars missing");
  _service = createClient(url, key, { auth: { persistSession: false } });
  return _service;
}

export function supabaseAnon(): SupabaseClient {
  if (_anon) return _anon;
  const url = supabaseUrl();
  const key = anonKey();
  if (!url || !key) throw new Error("Supabase anon env vars missing");
  _anon = createClient(url, key, { auth: { persistSession: false } });
  return _anon;
}
