# Deeplink install from marketplace — design

Date: 2026-04-21
Scope: snor-oh (Swift) + ani-mime (Tauri) + marketplace (Next.js)

## Goal

One-click install of a marketplace package into the matching desktop app via
a custom URL scheme, replacing the current download-then-import flow for
users who have the app installed.

## URL contract

```
animime://install?id=<pkg_id>[&v=1]
snoroh://install?id=<pkg_id>[&v=1]
```

- Scheme selects target app. Wrong-format packages are rejected by the app
  after fetching metadata (defense in depth).
- `id` is the marketplace package id. Must match `[A-Za-z0-9_-]{1,64}`.
- Host is always `install`. Unknown hosts are ignored with an error bubble.
- `v=1` is reserved for future payload fields; defaults to 1 when absent.

Both apps use the existing public endpoints:

- `GET /api/packages/:id` — metadata (name, creator, size, format, frame_counts)
- `GET /api/packages/:id/preview` — preview sprite strip
- `GET /api/packages/:id/download` — raw bundle bytes

No new API routes.

## Data flow

```
Marketplace card
  └─ [Install] click
     ├─ window.location = "<scheme>://install?id=<pkg>"
     ├─ setTimeout(1500) → if document.visibilityState still "visible":
     │     show "App not installed?" modal with release link + plain download
     └─ [Download] button unchanged

ani-mime (Tauri)
  tauri-plugin-deep-link → on_open_url → deeplink::handle
    → parse + validate id
    → fetch /api/packages/:id (metadata)
    → emit Tauri event "install-prompt" with { id, name, creator, size, preview_url, download_url }
    → frontend useInstallPrompt listens → InstallPromptDialog opens
    → on confirm: fetch download_url → importFromBytes() → reload library

snor-oh (Swift)
  Info.plist CFBundleURLTypes (snoroh://) →
  AppDelegate.handleURLEvent(kAEGetURL) →
  InstallCoordinator.handle(url)
    → parse + validate id
    → fetch metadata + bundle bytes
    → set @Observable pending prompt
    → Panel shows .sheet(InstallPromptView)
    → on confirm: write tmp file → OhhExporter.importOhh → bubble "installed"
```

## Marketplace changes (Next.js)

| File | Change |
|------|--------|
| `marketplace/lib/deeplink.ts` (new) | `buildInstallUrl(format, id)` + `DOWNLOAD_URL` map |
| `marketplace/app/gallery.tsx` | `PackageCard` adds Install button + fallback timer |
| `marketplace/app/install-fallback.tsx` (new) | Modal: release link + plain download |

```ts
// lib/deeplink.ts
export type PkgFormat = "snoroh" | "animime";

const SCHEME: Record<PkgFormat, string> = {
  animime: "animime",
  snoroh: "snoroh",
};

export function buildInstallUrl(format: PkgFormat, id: string): string {
  return `${SCHEME[format]}://install?id=${encodeURIComponent(id)}&v=1`;
}

export const DOWNLOAD_URL: Record<PkgFormat, string> = {
  animime: "https://github.com/vietnguyenhoangw/ani-mime/releases/latest",
  snoroh: "https://github.com/thanh-dong/snor-oh/releases/latest",
};
```

Install button click handler:

1. `window.location = buildInstallUrl(pkg.format, pkg.id)`
2. Start 1500ms timer
3. Listen `visibilitychange` + `pagehide` to cancel timer (app focused)
4. On timeout: open fallback modal

Modal: "App not installed? [Get <app>] [Download package only]" plus
X and backdrop close. `role="dialog"`, `aria-modal`, focus trap first button.

## ani-mime changes (Tauri)

| File | Change |
|------|--------|
| `src-tauri/Cargo.toml` | add `tauri-plugin-deep-link = "2"` |
| `src-tauri/Info.plist` | add `CFBundleURLTypes` with `animime` scheme |
| `src-tauri/tauri.conf.json` | `plugins.deep-link` schemes |
| `src-tauri/src/deeplink.rs` (new) | URL parse, fetch metadata, emit event |
| `src-tauri/src/lib.rs` | register plugin + `on_open_url` handler |
| `src/hooks/useInstallPrompt.ts` (new) | listen event, manage dialog state |
| `src/components/InstallPromptDialog.tsx` (new) | confirm dialog |
| `src/hooks/useCustomMimes.ts` | expose `importFromBytes(bytes, filename)` |
| `src/App.tsx` | mount `<InstallPromptDialog />` |

```xml
<!-- Info.plist -->
<key>CFBundleURLTypes</key>
<array>
  <dict>
    <key>CFBundleURLName</key>
    <string>com.ani-mime.deeplink</string>
    <key>CFBundleURLSchemes</key>
    <array><string>animime</string></array>
  </dict>
</array>
```

```rust
// src-tauri/src/deeplink.rs
use tauri::{AppHandle, Emitter};
use url::Url;

const MARKETPLACE_BASE: &str = "https://<marketplace-host>";

#[derive(serde::Serialize, Clone)]
struct InstallPromptPayload {
    id: String,
    name: String,
    creator: Option<String>,
    size_bytes: u64,
    preview_url: String,
    download_url: String,
}

pub async fn handle(app: AppHandle, raw_url: String) {
    let Ok(url) = Url::parse(&raw_url) else { return };
    if url.scheme() != "animime" { return; }
    if url.host_str() != Some("install") { return; }

    let id = url.query_pairs()
        .find(|(k, _)| k == "id")
        .map(|(_, v)| v.into_owned());
    let Some(id) = id else { return };
    if !id.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
        || id.is_empty() || id.len() > 64 { return; }

    let meta_url = format!("{MARKETPLACE_BASE}/api/packages/{id}");
    let Ok(resp) = reqwest::get(&meta_url).await else { return };
    let Ok(meta) = resp.json::<serde_json::Value>().await else { return };

    if meta["format"].as_str() != Some("animime") {
        // emit an error-bubble event here; front-end shows "wrong format"
        return;
    }

    let payload = InstallPromptPayload {
        id: id.clone(),
        name: meta["name"].as_str().unwrap_or("").to_string(),
        creator: meta["creator"].as_str().map(String::from),
        size_bytes: meta["size_bytes"].as_u64().unwrap_or(0),
        preview_url: format!("{MARKETPLACE_BASE}/api/packages/{id}/preview"),
        download_url: format!("{MARKETPLACE_BASE}/api/packages/{id}/download"),
    };
    let _ = app.emit("install-prompt", payload);
}
```

```rust
// src-tauri/src/lib.rs (inside run())
.plugin(tauri_plugin_deep_link::init())
.setup(|app| {
    use tauri_plugin_deep_link::DeepLinkExt;
    let handle = app.handle().clone();
    app.deep_link().on_open_url(move |event| {
        for url in event.urls() {
            let h = handle.clone();
            let raw = url.to_string();
            tauri::async_runtime::spawn(crate::deeplink::handle(h, raw));
        }
    });
    Ok(())
})
```

Single-instance: plugin integrates with `tauri-plugin-single-instance`. If
ani-mime does not already depend on it, add it. Without it, clicking the
deeplink while the app is running would spawn a second instance on Linux.

Frontend:

```ts
// hooks/useInstallPrompt.ts (sketch)
export function useInstallPrompt() {
  const [prompt, setPrompt] = useState<Payload | null>(null);
  useEffect(() => {
    const off = listen<Payload>("install-prompt", (e) => setPrompt(e.payload));
    return () => { off.then((fn) => fn()); };
  }, []);
  return { prompt, clear: () => setPrompt(null) };
}
```

Dialog body: animated preview (canvas, same 80ms/frame as Mascot),
name, creator, "X KB", [Install] [Cancel]. On Install: fetch
`download_url`, call `importFromBytes(new Uint8Array(await res.arrayBuffer()))`.
Format-magic validation lives in existing `importFromBytes`.

## snor-oh changes (Swift)

| File | Change |
|------|--------|
| `Info.plist` | add `CFBundleURLTypes` with `snoroh` scheme |
| `project.yml` | mirror URL types if XcodeGen regenerates Info.plist |
| `Sources/App/AppDelegate.swift` | register `kAEGetURL` handler |
| `Sources/Core/InstallCoordinator.swift` (new) | URL parse + fetch + pending prompt state |
| `Sources/Views/InstallPromptView.swift` (new) | SwiftUI sheet |
| `Sources/Views/SnorOhPanelView.swift` | `.sheet(item:)` bound to coordinator |
| `Sources/Network/MarketplaceClient.swift` | `fetchMeta(id:)`, `fetchBundle(id:)`, `previewURL(id:)` |

```xml
<!-- Info.plist -->
<key>CFBundleURLTypes</key>
<array>
  <dict>
    <key>CFBundleURLName</key>
    <string>com.snoroh.deeplink</string>
    <key>CFBundleURLSchemes</key>
    <array><string>snoroh</string></array>
  </dict>
</array>
```

```swift
// AppDelegate.applicationDidFinishLaunching(_:)
NSAppleEventManager.shared().setEventHandler(
    self,
    andSelector: #selector(handleURLEvent(_:withReplyEvent:)),
    forEventClass: AEEventClass(kInternetEventClass),
    andEventID: AEEventID(kAEGetURL)
)

@objc func handleURLEvent(_ event: NSAppleEventDescriptor,
                          withReplyEvent: NSAppleEventDescriptor) {
    guard let str = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
          let url = URL(string: str) else { return }
    InstallCoordinator.shared.handle(url: url)
    DispatchQueue.main.async { self.showPanel() }
}
```

```swift
// InstallCoordinator.swift
@Observable @MainActor
final class InstallCoordinator {
    static let shared = InstallCoordinator()
    var pending: Prompt?

    struct Prompt: Identifiable {
        let id: String
        let name: String
        let creator: String?
        let sizeBytes: Int
        let previewURL: URL
        let bundleData: Data
    }

    func handle(url: URL) {
        guard url.scheme == "snoroh", url.host == "install" else { return }
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        guard let id = comps?.queryItems?.first(where: { $0.name == "id" })?.value,
              id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }),
              !id.isEmpty, id.count <= 64 else { return }
        Task { await fetchAndPrompt(id: id) }
    }

    private func fetchAndPrompt(id: String) async {
        do {
            let meta   = try await MarketplaceClient.fetchMeta(id: id)
            guard meta.format == "snoroh" else {
                BubbleManager.shared.show("Wrong format — that's an .animime package")
                return
            }
            let bundle = try await MarketplaceClient.fetchBundle(id: id)
            pending = Prompt(
                id: id, name: meta.name, creator: meta.creator,
                sizeBytes: bundle.count,
                previewURL: MarketplaceClient.previewURL(id: id),
                bundleData: bundle
            )
        } catch {
            BubbleManager.shared.show("Marketplace fetch failed")
        }
    }

    func confirm() {
        guard let p = pending else { return }
        do {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(p.id).snoroh")
            try p.bundleData.write(to: tmp)
            try OhhExporter.importOhh(from: tmp)
            BubbleManager.shared.show("Installed \(p.name)")
        } catch {
            BubbleManager.shared.show("Install failed: \(error.localizedDescription)")
        }
        pending = nil
    }

    func cancel() { pending = nil }
}
```

Panel wiring:

```swift
.sheet(item: Binding(
    get: { InstallCoordinator.shared.pending },
    set: { if $0 == nil { InstallCoordinator.shared.cancel() } }
)) { prompt in
    InstallPromptView(prompt: prompt)
}
```

`InstallPromptView` reuses `AnimatedSpriteView` for the preview (load
strip from `previewURL`), shows name, creator, size, [Install] [Cancel].

## Error handling

| Scenario | Behavior |
|----------|----------|
| Malformed URL / wrong scheme / wrong host | silently ignore |
| Missing or bad `id` | silently ignore |
| Marketplace fetch fails (network / 404) | error bubble, no dialog |
| Format mismatch (wrong app for package) | error bubble "wrong format" |
| Bundle exceeds 2 MiB | reject in `OhhExporter.importOhh` / `importFromBytes` |
| Bundle fails magic-byte validation | reject via existing importer |
| Second deeplink arrives while prompt is open | latest wins; overwrite pending |

No auto-install path. Confirm dialog is mandatory — this is the drive-by
protection the scheme needs since any webpage can trigger a custom URL.

## Testing

| Test | Where | What |
|------|-------|------|
| `buildInstallUrl` | `marketplace/__tests__/deeplink.test.ts` | Encoding, scheme mapping |
| Install button + fallback timer | `marketplace/__tests__/gallery.test.tsx` | Timer fires, modal opens |
| URL parse (valid, wrong scheme/host, bad chars, long id, format mismatch) | `Tests/InstallCoordinatorTests.swift` | Pure logic, no network |
| Deep-link emits `install-prompt` | `ani-mime e2e/install-deeplink.spec.ts` | Mock event → dialog renders → import called |
| End-to-end manual | both apps | Click Install on marketplace staging → confirm dialog → package appears in library |

## Out of scope

- Marketplace search/filter by app format (future)
- Signed packages / trust levels (future)
- Update flow for already-installed packages (future — currently treated as new install)
- Windows support for either app (ani-mime Windows is unsupported today; snor-oh is macOS-only)
