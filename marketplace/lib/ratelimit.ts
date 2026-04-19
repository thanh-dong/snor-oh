import { Ratelimit } from "@upstash/ratelimit";
import { Redis } from "@upstash/redis";
import crypto from "node:crypto";

let _redis: Redis | null = null;
let _upload: Ratelimit | null = null;
let _download: Ratelimit | null = null;

function redis(): Redis {
  if (_redis) return _redis;
  const url = process.env.UPSTASH_REDIS_REST_URL;
  const token = process.env.UPSTASH_REDIS_REST_TOKEN;
  if (!url || !token) throw new Error("Upstash env vars missing");
  _redis = new Redis({ url, token });
  return _redis;
}

export function uploadLimiter(): Ratelimit {
  if (_upload) return _upload;
  _upload = new Ratelimit({
    redis: redis(),
    limiter: Ratelimit.slidingWindow(5, "1 d"),
    prefix: "snoroh:upload",
    analytics: false,
  });
  return _upload;
}

export function downloadLimiter(): Ratelimit {
  if (_download) return _download;
  _download = new Ratelimit({
    redis: redis(),
    limiter: Ratelimit.slidingWindow(100, "1 d"),
    prefix: "snoroh:download",
    analytics: false,
  });
  return _download;
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
