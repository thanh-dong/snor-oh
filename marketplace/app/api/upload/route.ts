import { NextResponse } from "next/server";
import { validatePackage, ValidationError, MAX_FILE_BYTES } from "@/lib/validate";
import { supabaseService, BUCKET } from "@/lib/supabase";
import { uploadLimiter, clientIp, hashIp } from "@/lib/ratelimit";

export const runtime = "nodejs";
export const maxDuration = 30;

function err(code: string, message: string, status = 400) {
  return NextResponse.json({ error: { code, message } }, { status });
}

export async function POST(req: Request) {
  const ip = clientIp(req);
  const ipHash = hashIp(ip);

  const { success, remaining, reset } = await uploadLimiter().limit(ipHash);
  if (!success) {
    return NextResponse.json(
      { error: { code: "rate_limited", message: "Daily upload limit reached" } },
      { status: 429, headers: { "x-ratelimit-reset": String(reset) } }
    );
  }

  let form: FormData;
  try {
    form = await req.formData();
  } catch {
    return err("invalid_body", "Expected multipart/form-data");
  }

  const file = form.get("file");
  if (!(file instanceof Blob)) return err("no_file", "Missing file field");
  if (file.size > MAX_FILE_BYTES) return err("too_large", "File exceeds 2 MiB");

  const filename = (form.get("filename") as string | null)?.trim() ?? "";
  const creatorRaw = (form.get("creator") as string | null)?.trim() ?? "";
  const creator = creatorRaw.length > 0 ? creatorRaw.slice(0, 40) : null;

  const ext = filename.toLowerCase().endsWith(".animime") ? "animime" : "snoroh";

  const buf = Buffer.from(await file.arrayBuffer());

  let validated;
  try {
    validated = await validatePackage(buf);
  } catch (e) {
    if (e instanceof ValidationError) return err(e.code, e.message);
    return err("validation_failed", "Package failed validation", 400);
  }

  const db = supabaseService();
  const storagePath = `${crypto.randomUUID()}.${ext}`;

  const { error: uploadErr } = await db.storage
    .from(BUCKET)
    .upload(storagePath, buf, {
      contentType: "application/json",
      upsert: false,
    });
  if (uploadErr) {
    return err("storage_failed", uploadErr.message, 500);
  }

  const { data: row, error: insertErr } = await db
    .from("packages")
    .insert({
      name: validated.name,
      creator,
      format: ext,
      storage_path: storagePath,
      size_bytes: buf.byteLength,
      frame_counts: validated.frameCounts,
      preview_png: validated.previewPng,
      ip_hash: ipHash,
    })
    .select("id")
    .single();

  if (insertErr || !row) {
    await db.storage.from(BUCKET).remove([storagePath]);
    return err("db_failed", insertErr?.message ?? "Insert failed", 500);
  }

  return NextResponse.json({ id: row.id, remaining });
}
