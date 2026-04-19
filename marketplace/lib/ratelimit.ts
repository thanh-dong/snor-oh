import IORedis, { type Redis } from "ioredis";
import crypto from "node:crypto";

const UPLOAD_LIMIT = 5;       // per IP per day
const DOWNLOAD_LIMIT = 100;   // per IP per day
const DAY_SECONDS = 24 * 60 * 60;

let _redis: Redis | null = null;

function redisUrl(): string | undefined {
  return (
    process.env.snoroh_REDIS_URL ??
    process.env.REDIS_URL ??
    process.env.UPSTASH_REDIS_URL
  );
}

function redis(): Redis {
  if (_redis) return _redis;
  const url = redisUrl();
  if (!url) throw new Error("Redis env var missing (snoroh_REDIS_URL / REDIS_URL)");
  _redis = new IORedis(url, {
    maxRetriesPerRequest: 3,
    lazyConnect: false,
    // TLS is inferred from rediss:// scheme; for plain redis:// we don't force it.
    tls: url.startsWith("rediss://") ? {} : undefined,
  });
  return _redis;
}

export interface LimitResult {
  success: boolean;
  remaining: number;
  limit: number;
  reset: number; // unix seconds when window resets
}

async function bucketLimit(kind: "upload" | "download", ipHash: string, limit: number): Promise<LimitResult> {
  const bucket = Math.floor(Date.now() / 1000 / DAY_SECONDS);
  const key = `snoroh:${kind}:${ipHash}:${bucket}`;
  const reset = (bucket + 1) * DAY_SECONDS;

  const client = redis();
  const [countRes, _expRes] = await client
    .multi()
    .incr(key)
    .expire(key, DAY_SECONDS)
    .exec() as [[Error | null, number], [Error | null, number]];

  const count = countRes?.[1] ?? 0;
  return {
    success: count <= limit,
    remaining: Math.max(0, limit - count),
    limit,
    reset,
  };
}

export function limitUpload(ipHash: string): Promise<LimitResult> {
  return bucketLimit("upload", ipHash, UPLOAD_LIMIT);
}

export function limitDownload(ipHash: string): Promise<LimitResult> {
  return bucketLimit("download", ipHash, DOWNLOAD_LIMIT);
}

export function hashIp(ip: string): string {
  const salt = process.env.IP_HASH_SALT ?? "snoroh-default-salt";
  return crypto.createHash("sha256").update(`${salt}:${ip}`).digest("hex").slice(0, 32);
}

export function clientIp(req: Request): string {
  const fwd = req.headers.get("x-forwarded-for");
  if (fwd) return fwd.split(",")[0].trim();
  const real = req.headers.get("x-real-ip");
  if (real) return real;
  return "0.0.0.0";
}
