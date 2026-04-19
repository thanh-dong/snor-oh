import { Gallery } from "./gallery";
import { UploadForm } from "./upload-form";

export const dynamic = "force-dynamic";

export default function Home() {
  return (
    <main className="mx-auto max-w-5xl px-6 py-10">
      <header className="mb-10 flex flex-wrap items-end justify-between gap-4">
        <div>
          <h1 className="text-3xl font-semibold tracking-tight">snor-oh marketplace</h1>
          <p className="mt-2 text-sm opacity-70">
            Browse and share <code className="font-mono">.snoroh</code> and{" "}
            <code className="font-mono">.animime</code> mascot packages.
          </p>
        </div>
        <UploadForm />
      </header>
      <Gallery />
    </main>
  );
}
