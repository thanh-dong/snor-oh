import { NextResponse } from "next/server";
import IORedis from "ioredis";

export const runtime = "nodejs";
export const maxDuration = 30;

function authorized(req: Request): boolean {
  const token = process.env.ADMIN_TOKEN;
  if (!token || token === "changeme") return false;
  const header = req.headers.get("authorization") ?? "";
  const [scheme, value] = header.split(" ", 2);
  return scheme === "Bearer" && value === token;
}

function redisUrl(): string | undefined {
  return (
    process.env.snoroh_REDIS_URL ??
    process.env.REDIS_URL ??
    process.env.UPSTASH_REDIS_URL
  );
}

async function scanDelete(pattern: string): Promise<number> {
  const url = redisUrl();
  if (!url) throw new Error("Redis env var missing");
  const client = new IORedis(url, {
    maxRetriesPerRequest: 3,
    lazyConnect: false,
    tls: url.startsWith("rediss://") ? {} : undefined,
  });
  try {
    let cursor = "0";
    let deleted = 0;
    do {
      const [next, keys] = await client.scan(cursor, "MATCH", pattern, "COUNT", 500);
      cursor = next;
      if (keys.length > 0) {
        deleted += await client.del(...keys);
      }
    } while (cursor !== "0");
    return deleted;
  } finally {
    client.disconnect();
  }
}

// DELETE /api/admin/ratelimit?kind=upload|download|all
export async function DELETE(req: Request) {
  if (!authorized(req)) {
    return NextResponse.json(
      { error: { code: "unauthorized", message: "Invalid admin token" } },
      { status: 401 }
    );
  }

  const kind = new URL(req.url).searchParams.get("kind") ?? "upload";
  const patterns: Record<string, string> = {
    upload: "snoroh:upload:*",
    download: "snoroh:download:*",
    all: "snoroh:*",
  };
  const pattern = patterns[kind];
  if (!pattern) {
    return NextResponse.json(
      { error: { code: "bad_kind", message: "kind must be upload|download|all" } },
      { status: 400 }
    );
  }

  try {
    const deleted = await scanDelete(pattern);
    return NextResponse.json({ ok: true, kind, pattern, deleted });
  } catch (e) {
    return NextResponse.json(
      { error: { code: "redis_failed", message: e instanceof Error ? e.message : "reset failed" } },
      { status: 500 }
    );
  }
}
