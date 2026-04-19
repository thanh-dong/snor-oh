import { NextResponse } from "next/server";
import { supabaseAnon } from "@/lib/supabase";

export const runtime = "nodejs";

const PAGE_SIZE = 24;

export async function GET(req: Request) {
  const url = new URL(req.url);
  const cursor = url.searchParams.get("cursor"); // ISO timestamp
  const limit = Math.min(Number(url.searchParams.get("limit") ?? PAGE_SIZE), 48);

  let q = supabaseAnon()
    .from("packages")
    .select("id, name, creator, format, size_bytes, frame_counts, preview_png, created_at")
    .order("created_at", { ascending: false })
    .limit(limit + 1);

  if (cursor) q = q.lt("created_at", cursor);

  const { data, error } = await q;
  if (error) {
    return NextResponse.json({ error: { code: "query_failed", message: error.message } }, { status: 500 });
  }

  const hasMore = (data?.length ?? 0) > limit;
  const items = hasMore ? data!.slice(0, limit) : (data ?? []);
  const nextCursor = hasMore ? items[items.length - 1].created_at : null;

  return NextResponse.json({ items, nextCursor });
}
