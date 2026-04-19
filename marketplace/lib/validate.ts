import sharp from "sharp";
import { STATUSES, type SnorohFile, type SpriteEntry } from "./schema";

export const MAX_FILE_BYTES = 2 * 1024 * 1024; // 2 MiB
export const MAX_SPRITE_DIM = 1024;

export interface ValidatedPackage {
  name: string;
  version: number;
  sprites: Record<string, { frames: number; pngBytes: number }>;
  previewPng: string; // base64 of idle sprite
  frameCounts: Record<string, number>;
}

export class ValidationError extends Error {
  readonly code: string;
  constructor(code: string, message: string) {
    super(message);
    this.code = code;
  }
}

function isSpriteEntry(v: unknown): v is SpriteEntry {
  return (
    typeof v === "object" &&
    v !== null &&
    typeof (v as SpriteEntry).frames === "number" &&
    typeof (v as SpriteEntry).data === "string"
  );
}

function isSnorohFile(v: unknown): v is SnorohFile {
  if (typeof v !== "object" || v === null) return false;
  const f = v as SnorohFile;
  if (typeof f.version !== "number" || typeof f.name !== "string") return false;
  if (typeof f.sprites !== "object" || f.sprites === null) return false;
  return true;
}

export async function validatePackage(buf: Buffer): Promise<ValidatedPackage> {
  if (buf.byteLength > MAX_FILE_BYTES) {
    throw new ValidationError("too_large", `File exceeds ${MAX_FILE_BYTES} bytes`);
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(buf.toString("utf8"));
  } catch {
    throw new ValidationError("invalid_json", "File is not valid JSON");
  }

  if (!isSnorohFile(parsed)) {
    throw new ValidationError("invalid_schema", "Missing version/name/sprites");
  }
  if (parsed.version !== 1) {
    throw new ValidationError("unsupported_version", `Version ${parsed.version} not supported`);
  }
  const name = parsed.name.trim();
  if (name.length === 0 || name.length > 80) {
    throw new ValidationError("invalid_name", "Name must be 1–80 chars");
  }

  const sprites: ValidatedPackage["sprites"] = {};
  const frameCounts: Record<string, number> = {};
  let previewPng: string | null = null;

  for (const status of STATUSES) {
    const entry = parsed.sprites[status];
    if (!isSpriteEntry(entry)) {
      throw new ValidationError("missing_sprite", `Missing sprite for "${status}"`);
    }
    if (!Number.isInteger(entry.frames) || entry.frames < 1 || entry.frames > 64) {
      throw new ValidationError("invalid_frames", `Frame count for "${status}" must be 1–64`);
    }

    let pngBuf: Buffer;
    try {
      pngBuf = Buffer.from(entry.data, "base64");
    } catch {
      throw new ValidationError("invalid_base64", `Sprite "${status}" is not valid base64`);
    }
    if (pngBuf.byteLength === 0) {
      throw new ValidationError("empty_sprite", `Sprite "${status}" is empty`);
    }

    // PNG magic: 89 50 4E 47 0D 0A 1A 0A
    const magic = pngBuf.subarray(0, 8);
    const expected = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
    if (!magic.equals(expected)) {
      throw new ValidationError("not_png", `Sprite "${status}" is not a PNG`);
    }

    try {
      const meta = await sharp(pngBuf).metadata();
      if (!meta.width || !meta.height) {
        throw new ValidationError("invalid_png", `Sprite "${status}" has no dimensions`);
      }
      if (meta.width > MAX_SPRITE_DIM || meta.height > MAX_SPRITE_DIM) {
        throw new ValidationError("png_too_large", `Sprite "${status}" exceeds ${MAX_SPRITE_DIM}px`);
      }
    } catch (e) {
      if (e instanceof ValidationError) throw e;
      throw new ValidationError("invalid_png", `Sprite "${status}" failed to decode`);
    }

    sprites[status] = { frames: entry.frames, pngBytes: pngBuf.byteLength };
    frameCounts[status] = entry.frames;
    if (status === "idle") previewPng = entry.data;
  }

  if (!previewPng) {
    throw new ValidationError("missing_sprite", 'Missing sprite for "idle"');
  }

  return { name, version: parsed.version, sprites, previewPng, frameCounts };
}
