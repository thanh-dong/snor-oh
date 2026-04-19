"use client";

import { useCallback, useEffect, useRef, useState } from "react";

interface PackageRow {
  id: string;
  name: string;
  creator: string | null;
  format: "snoroh" | "animime";
  size_bytes: number;
  frame_counts: Record<string, number>;
  preview_png: string;
  created_at: string;
}

interface PageResponse {
  items: PackageRow[];
  nextCursor: string | null;
}

async function fetchPage(cursor: string | null): Promise<PageResponse> {
  const url = cursor
    ? `/api/packages?cursor=${encodeURIComponent(cursor)}`
    : "/api/packages";
  const res = await fetch(url, { cache: "no-store" });
  if (!res.ok) throw new Error("Failed to load packages");
  return res.json();
}

export function Gallery() {
  const [items, setItems] = useState<PackageRow[]>([]);
  const [cursor, setCursor] = useState<string | null>(null);
  const [done, setDone] = useState(false);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const sentinelRef = useRef<HTMLDivElement | null>(null);
  const seenCursor = useRef<string | null | undefined>(undefined);

  const loadMore = useCallback(async () => {
    if (loading || done) return;
    if (seenCursor.current === cursor) return; // undefined on first call, so first fetch proceeds
    seenCursor.current = cursor;
    setLoading(true);
    setError(null);
    try {
      const page = await fetchPage(cursor);
      setItems((prev) => [...prev, ...page.items]);
      if (page.nextCursor) {
        setCursor(page.nextCursor);
      } else {
        setDone(true);
      }
    } catch (e) {
      setError(e instanceof Error ? e.message : "Error");
    } finally {
      setLoading(false);
    }
  }, [cursor, done, loading]);

  useEffect(() => {
    loadMore();
  }, [loadMore]);

  useEffect(() => {
    const el = sentinelRef.current;
    if (!el) return;
    const io = new IntersectionObserver((entries) => {
      if (entries[0].isIntersecting) loadMore();
    });
    io.observe(el);
    return () => io.disconnect();
  }, [loadMore]);

  if (items.length === 0 && loading) {
    return (
      <div className="grid grid-cols-2 gap-4 sm:grid-cols-3 lg:grid-cols-4">
        {Array.from({ length: 8 }).map((_, i) => (
          <SkeletonCard key={i} />
        ))}
      </div>
    );
  }

  if (items.length === 0 && done) {
    return (
      <div className="rounded-2xl border border-dashed border-[color:var(--border)] bg-[color:var(--bg-subtle)] p-16 text-center">
        <div className="mb-2 text-2xl">(´･ω･`)</div>
        <p className="text-sm opacity-60">No packages yet. Drop yours above to be the first.</p>
      </div>
    );
  }

  return (
    <div>
      <div className="grid grid-cols-2 gap-4 sm:grid-cols-3 lg:grid-cols-4">
        {items.map((p) => (
          <PackageCard key={p.id} pkg={p} />
        ))}
      </div>
      {error && (
        <p className="mt-6 rounded-md border border-red-500/30 bg-red-500/10 px-3 py-2 text-sm text-red-700 dark:text-red-400">
          {error}
        </p>
      )}
      <div ref={sentinelRef} className="h-10" />
      {loading && items.length > 0 && (
        <p className="mt-4 text-center font-mono text-[11px] opacity-50">loading…</p>
      )}
      {done && items.length > 0 && (
        <p className="mt-8 text-center font-mono text-[10px] uppercase tracking-widest opacity-40">
          — end of list · {items.length} packages —
        </p>
      )}
    </div>
  );
}

function PackageCard({ pkg }: { pkg: PackageRow }) {
  const idleFrames = pkg.frame_counts.idle ?? 1;
  const dateLabel = timeAgo(pkg.created_at);
  const sizeKb = Math.round(pkg.size_bytes / 1024);

  return (
    <div className="group flex flex-col overflow-hidden rounded-xl border border-[color:var(--card-border)] bg-[color:var(--card)] shadow-sm transition hover:-translate-y-0.5 hover:border-[color:var(--accent)]/40 hover:shadow-md">
      <div className="relative aspect-square overflow-hidden bg-[color:var(--bg-subtle)]">
        <AnimatedPreview base64Png={pkg.preview_png} frames={idleFrames} />
        <span className="absolute right-2 top-2 rounded-md bg-[color:var(--bg)]/80 px-1.5 py-0.5 font-mono text-[9px] uppercase tracking-widest opacity-70 backdrop-blur-sm">
          .{pkg.format}
        </span>
      </div>
      <div className="flex flex-1 flex-col gap-1 p-3">
        <div className="truncate text-sm font-medium" title={pkg.name}>
          {pkg.name}
        </div>
        <div className="flex items-center justify-between gap-2 text-xs opacity-60">
          <span className="truncate font-mono">{pkg.creator ?? "anonymous"}</span>
          <span className="font-mono text-[10px]">{sizeKb} KB</span>
        </div>
        <div className="mt-2 flex items-center justify-between gap-2">
          <span className="font-mono text-[10px] opacity-50">{dateLabel}</span>
          <a
            href={`/api/packages/${pkg.id}/download`}
            className="rounded-md border border-[color:var(--border)] px-2.5 py-1 font-mono text-[10px] uppercase tracking-widest transition hover:border-[color:var(--accent)] hover:bg-[color:var(--accent)] hover:text-[color:var(--accent-fg)]"
            download
          >
            download
          </a>
        </div>
      </div>
    </div>
  );
}

function SkeletonCard() {
  return (
    <div className="flex flex-col overflow-hidden rounded-xl border border-[color:var(--card-border)] bg-[color:var(--card)]">
      <div className="aspect-square animate-pulse bg-[color:var(--bg-subtle)]" />
      <div className="space-y-2 p-3">
        <div className="h-3 w-3/4 animate-pulse rounded bg-[color:var(--bg-subtle)]" />
        <div className="h-3 w-1/2 animate-pulse rounded bg-[color:var(--bg-subtle)]" />
      </div>
    </div>
  );
}

function timeAgo(iso: string): string {
  const then = new Date(iso).getTime();
  const diff = Date.now() - then;
  const s = Math.floor(diff / 1000);
  if (s < 60) return "just now";
  const m = Math.floor(s / 60);
  if (m < 60) return `${m}m ago`;
  const h = Math.floor(m / 60);
  if (h < 24) return `${h}h ago`;
  const d = Math.floor(h / 24);
  if (d < 30) return `${d}d ago`;
  return new Date(iso).toLocaleDateString();
}

function AnimatedPreview({ base64Png, frames }: { base64Png: string; frames: number }) {
  const canvasRef = useRef<HTMLCanvasElement | null>(null);

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const ctx = canvas.getContext("2d");
    if (!ctx) return;

    const img = new Image();
    let raf = 0;
    let cancelled = false;

    img.onload = () => {
      if (cancelled) return;
      const frameW = Math.max(1, Math.floor(img.width / frames));
      const frameH = img.height;
      const scale = Math.min(canvas.width / frameW, canvas.height / frameH) * 0.8;
      const drawW = frameW * scale;
      const drawH = frameH * scale;
      const offsetX = (canvas.width - drawW) / 2;
      const offsetY = (canvas.height - drawH) / 2;

      let current = 0;
      let last = performance.now();
      const frameMs = 80; // match Swift SpriteEngine

      const loop = (now: number) => {
        if (cancelled) return;
        if (now - last >= frameMs) {
          current = (current + 1) % frames;
          last = now;
        }
        ctx.imageSmoothingEnabled = false;
        ctx.clearRect(0, 0, canvas.width, canvas.height);
        ctx.drawImage(
          img,
          current * frameW,
          0,
          frameW,
          frameH,
          offsetX,
          offsetY,
          drawW,
          drawH
        );
        raf = requestAnimationFrame(loop);
      };
      raf = requestAnimationFrame(loop);
    };
    img.src = `data:image/png;base64,${base64Png}`;

    return () => {
      cancelled = true;
      cancelAnimationFrame(raf);
    };
  }, [base64Png, frames]);

  return (
    <canvas
      ref={canvasRef}
      width={256}
      height={256}
      className="pixel h-full w-full"
    />
  );
}
