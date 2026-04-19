import { NextResponse } from "next/server";
import { supabaseService, BUCKET } from "@/lib/supabase";

export const runtime = "nodejs";

function authorized(req: Request): boolean {
  const token = process.env.ADMIN_TOKEN;
  if (!token || token === "changeme") return false;
  const header = req.headers.get("authorization") ?? "";
  const [scheme, value] = header.split(" ", 2);
  return scheme === "Bearer" && value === token;
}

export async function DELETE(req: Request, ctx: { params: Promise<{ id: string }> }) {
  if (!authorized(req)) {
    return NextResponse.json({ error: { code: "unauthorized", message: "Invalid admin token" } }, { status: 401 });
  }
  const { id } = await ctx.params;
  const db = supabaseService();

  const { data: row, error: selErr } = await db
    .from("packages")
    .select("storage_path")
    .eq("id", id)
    .single();
  if (selErr || !row) {
    return NextResponse.json({ error: { code: "not_found", message: "Package not found" } }, { status: 404 });
  }

  await db.storage.from(BUCKET).remove([row.storage_path]);
  const { error: delErr } = await db.from("packages").delete().eq("id", id);
  if (delErr) {
    return NextResponse.json({ error: { code: "db_failed", message: delErr.message } }, { status: 500 });
  }
  return NextResponse.json({ ok: true });
}
