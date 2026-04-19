import { createClient, type SupabaseClient } from "@supabase/supabase-js";

export const BUCKET = "packages";

let _service: SupabaseClient | null = null;
let _anon: SupabaseClient | null = null;

export function supabaseService(): SupabaseClient {
  if (_service) return _service;
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !key) throw new Error("Supabase service env vars missing");
  _service = createClient(url, key, { auth: { persistSession: false } });
  return _service;
}

export function supabaseAnon(): SupabaseClient {
  if (_anon) return _anon;
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
  if (!url || !key) throw new Error("Supabase anon env vars missing");
  _anon = createClient(url, key, { auth: { persistSession: false } });
  return _anon;
}
