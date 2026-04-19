"use client";

import { useRef, useState } from "react";

export function UploadForm() {
  const [open, setOpen] = useState(false);
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState<{ kind: "err" | "ok"; text: string } | null>(null);
  const fileRef = useRef<HTMLInputElement | null>(null);
  const creatorRef = useRef<HTMLInputElement | null>(null);

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    const file = fileRef.current?.files?.[0];
    if (!file) {
      setMessage({ kind: "err", text: "Pick a .snoroh or .animime file first" });
      return;
    }
    const name = file.name.toLowerCase();
    if (!name.endsWith(".snoroh") && !name.endsWith(".animime")) {
      setMessage({ kind: "err", text: "File must end in .snoroh or .animime" });
      return;
    }

    setBusy(true);
    setMessage(null);
    try {
      const fd = new FormData();
      fd.set("file", file);
      fd.set("filename", file.name);
      fd.set("creator", creatorRef.current?.value ?? "");
      const res = await fetch("/api/upload", { method: "POST", body: fd });
      const data = await res.json();
      if (!res.ok) {
        setMessage({ kind: "err", text: data?.error?.message ?? "Upload failed" });
      } else {
        setMessage({ kind: "ok", text: "Uploaded. Refreshing…" });
        setTimeout(() => location.reload(), 500);
      }
    } catch (e) {
      setMessage({ kind: "err", text: e instanceof Error ? e.message : "Upload failed" });
    } finally {
      setBusy(false);
    }
  }

  if (!open) {
    return (
      <button
        className="rounded-md bg-black px-4 py-2 text-sm font-medium text-white hover:bg-neutral-800 dark:bg-white dark:text-black dark:hover:bg-neutral-200"
        onClick={() => setOpen(true)}
      >
        Share a package
      </button>
    );
  }

  return (
    <form
      onSubmit={submit}
      className="flex flex-col gap-3 rounded-xl border border-black/10 bg-white p-4 text-sm shadow-md dark:border-white/10 dark:bg-neutral-900"
    >
      <label className="flex flex-col gap-1">
        <span className="text-xs opacity-60">Package file</span>
        <input
          ref={fileRef}
          type="file"
          accept=".snoroh,.animime,application/json"
          className="text-xs"
        />
      </label>
      <label className="flex flex-col gap-1">
        <span className="text-xs opacity-60">Creator (optional, 40 chars)</span>
        <input
          ref={creatorRef}
          type="text"
          maxLength={40}
          className="rounded border border-black/10 bg-transparent px-2 py-1 text-sm dark:border-white/10"
          placeholder="@yourhandle"
        />
      </label>
      {message && (
        <p className={message.kind === "ok" ? "text-xs text-green-600" : "text-xs text-red-500"}>
          {message.text}
        </p>
      )}
      <div className="flex justify-end gap-2">
        <button
          type="button"
          className="rounded-md border border-black/10 px-3 py-1 text-xs dark:border-white/10"
          onClick={() => setOpen(false)}
          disabled={busy}
        >
          Cancel
        </button>
        <button
          type="submit"
          className="rounded-md bg-black px-3 py-1 text-xs font-medium text-white disabled:opacity-50 dark:bg-white dark:text-black"
          disabled={busy}
        >
          {busy ? "Uploading…" : "Upload"}
        </button>
      </div>
      <p className="text-[10px] opacity-50">
        5 uploads/day per IP. Packages are validated server-side.
      </p>
    </form>
  );
}
