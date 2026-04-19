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
  const seenCursor = useRef<string | null>(null);

  const loadMore = useCallback(async () => {
    if (loading || done) return;
    if (seenCursor.current === cursor) return;
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

  if (items.length === 0 && done) {
    return (
      <div className="rounded-xl border border-black/10 p-10 text-center text-sm opacity-60 dark:border-white/10">
        Nothing uploaded yet. Be the first!
      </div>
    );
  }

  return (
    <div>
      <div className="grid grid-cols-2 gap-4 sm:grid-cols-3 md:grid-cols-4">
        {items.map((p) => (
          <PackageCard key={p.id} pkg={p} />
        ))}
      </div>
      {error && <p className="mt-6 text-sm text-red-500">{error}</p>}
      <div ref={sentinelRef} className="h-10" />
      {loading && <p className="mt-4 text-center text-sm opacity-60">Loading…</p>}
      {done && items.length > 0 && (
        <p className="mt-8 text-center text-xs opacity-40">— end of list —</p>
      )}
    </div>
  );
}

function PackageCard({ pkg }: { pkg: PackageRow }) {
  const idleFrames = pkg.frame_counts.idle ?? 1;
  const dateLabel = new Date(pkg.created_at).toLocaleDateString();
  const sizeKb = Math.round(pkg.size_bytes / 1024);

  return (
    <div className="flex flex-col overflow-hidden rounded-xl border border-black/10 bg-white shadow-sm transition hover:shadow-md dark:border-white/10 dark:bg-neutral-900">
      <div className="aspect-square bg-neutral-50 dark:bg-neutral-950">
        <AnimatedPreview base64Png={pkg.preview_png} frames={idleFrames} />
      </div>
      <div className="flex flex-1 flex-col gap-1 p-3 text-sm">
        <div className="flex items-baseline justify-between gap-2">
          <span className="truncate font-medium" title={pkg.name}>
            {pkg.name}
          </span>
          <span className="font-mono text-[10px] uppercase opacity-50">.{pkg.format}</span>
        </div>
        <div className="flex items-center justify-between text-xs opacity-60">
          <span className="truncate">{pkg.creator ?? "anonymous"}</span>
          <span>{sizeKb} KB</span>
        </div>
        <div className="mt-2 flex items-center justify-between">
          <span className="text-[11px] opacity-50">{dateLabel}</span>
          <a
            href={`/api/packages/${pkg.id}/download`}
            className="rounded-md bg-black px-2 py-1 text-xs text-white hover:bg-neutral-800 dark:bg-white dark:text-black dark:hover:bg-neutral-200"
            download
          >
            Download
          </a>
        </div>
      </div>
    </div>
  );
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
      const scale = Math.min(canvas.width / frameW, canvas.height / frameH);
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
      className="h-full w-full"
      style={{ imageRendering: "pixelated" }}
    />
  );
}
