import { NextResponse } from "next/server";
import { supabaseService, BUCKET } from "@/lib/supabase";
import { downloadLimiter, clientIp, hashIp } from "@/lib/ratelimit";

export const runtime = "nodejs";

export async function GET(req: Request, ctx: { params: Promise<{ id: string }> }) {
  const { id } = await ctx.params;

  const ipHash = hashIp(clientIp(req));
  const { success } = await downloadLimiter().limit(ipHash);
  if (!success) {
    return NextResponse.json(
      { error: { code: "rate_limited", message: "Daily download limit reached" } },
      { status: 429 }
    );
  }

  const db = supabaseService();
  const { data: row, error } = await db
    .from("packages")
    .select("name, format, storage_path")
    .eq("id", id)
    .single();
  if (error || !row) {
    return NextResponse.json({ error: { code: "not_found", message: "Package not found" } }, { status: 404 });
  }

  const { data: blob, error: dlErr } = await db.storage.from(BUCKET).download(row.storage_path);
  if (dlErr || !blob) {
    return NextResponse.json({ error: { code: "storage_failed", message: dlErr?.message ?? "Download failed" } }, { status: 500 });
  }

  const safeName = row.name.replace(/[^a-zA-Z0-9_-]+/g, "-");
  const filename = `${safeName}.${row.format}`;
  const buf = Buffer.from(await blob.arrayBuffer());
  return new NextResponse(buf, {
    status: 200,
    headers: {
      "content-type": "application/json",
      "content-disposition": `attachment; filename="${filename}"`,
      "cache-control": "public, max-age=3600",
    },
  });
}
