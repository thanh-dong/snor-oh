# snor-oh Swift

Native macOS desktop mascot that reacts to terminal and Claude Code activity. snor-oh-style unified panel with per-project session cards.

## Quick Reference

- **Build**: `swift build`
- **Run**: `swift run`
- **Test**: `swift test`
- **Release**: `bash Scripts/build-release.sh` (outputs `.build/release-app/snor-oh.app`)
- **XcodeGen**: `xcodegen generate` (creates .xcodeproj)
- **Min macOS**: 14.0 (Sonoma) — required for @Observable

## Workflow

After completing a task, always build a release package for testing:

```bash
bash Scripts/build-release.sh
```

This creates a signed `.app` bundle at `.build/release-app/snor-oh.app`. Run it with `open .build/release-app/snor-oh.app` to verify changes work end-to-end.

## Architecture

```
Shell hooks (curl) → HTTP :1234 → SessionManager → SwiftUI Views
Claude Code ←stdio→ MCP server (Node.js) ←HTTP→ :1234 → SwiftUI Views
```

### App (`Sources/App/`)

| File | Responsibility |
|------|---------------|
| `SnorOhApp.swift` | @main entry, delegates to AppDelegate |
| `AppDelegate.swift` | Menu bar tray, SnorOhPanelWindow lifecycle, server startup, bubble observing |

### Core (`Sources/Core/`)

| File | Responsibility |
|------|---------------|
| `Types.swift` | Status enum, Session, PeerInfo, VisitingDog, ProjectStatus, all Codable payloads |
| `SessionManager.swift` | `@Observable` state: sessions, projects, peers, visitors, usage |
| `Watchdog.swift` | 2s timer: heartbeat timeout, service→idle, idle→sleep |
| `HTTPServer.swift` | SwiftNIO server on `127.0.0.1:1234`, all route handlers |

### Views (`Sources/Views/`)

| File | Responsibility |
|------|---------------|
| `SnorOhPanelWindow.swift` | NSPanel: unified panel window, position persistence, drag-to-reposition |
| `SnorOhPanelView.swift` | snor-oh-style panel: header mascot + collapsible project cards with per-project sprites |
| `MascotWindow.swift` | NSPanel: transparent standalone mascot (legacy, not instantiated) |
| `MascotView.swift` | Standalone mascot view + `AnimatedSpriteView` (reused by SnorOhPanelView) |
| `StatusPill.swift` | Colored dot + label (green/red/blue/yellow/gray/teal) |
| `SpeechBubble.swift` | Speech bubble view + BubbleManager (@Observable, auto-dismiss) |
| `VisitorView.swift` | Visiting peers display (up to 3 sprites at 48x48) |
| `SettingsView.swift` | Settings: General tab, Mime tab, About tab |
| `SettingsWindow.swift` | NSWindow wrapper with NSWindowDelegate cleanup |
| `SetupWizard.swift` | First-launch flow: Welcome → Installing → Done |

### Animation (`Sources/Animation/`)

| File | Responsibility |
|------|---------------|
| `SpriteConfig.swift` | Sprite sheet config: built-in + custom pet→filename→frameCount mapping |
| `SpriteCache.swift` | CGImage frame cache, extracts frames from PNG sprite sheets (built-in + custom) |
| `SpriteEngine.swift` | @Observable animation driver: 80ms/frame, auto-freeze on idle |

### Sprites (`Sources/Sprites/`)

| File | Responsibility |
|------|---------------|
| `CustomMimeManager.swift` | @Observable singleton: CRUD for custom pets, file storage in ~/.snor-oh/custom-sprites/ |
| `SmartImport.swift` | Sprite sheet processor: bg detection, row/column detection, frame extraction, grid packing |
| `MimeExporter.swift` | .snoroh file export/import (JSON with base64-encoded PNG per status) |

### Network (`Sources/Network/`)

| File | Responsibility |
|------|---------------|
| `GitStatus.swift` | Polls `git status --porcelain` per project (30s interval) |
| `PeerDiscovery.swift` | NWBrowser + NWListener for Bonjour peer discovery |
| `VisitManager.swift` | Sends visit/visit-end requests to peers |

### Setup (`Sources/Setup/`)

| File | Responsibility |
|------|---------------|
| `MCPInstaller.swift` | Copies server.mjs to ~/.snor-oh/mcp/, registers in ~/.claude.json |
| `ClaudeHooks.swift` | Configures Claude Code hooks in ~/.claude/settings.json |

### Util (`Sources/Util/`)

| File | Responsibility |
|------|---------------|
| `Defaults.swift` | `DefaultsKey` enum: all UserDefaults key constants |
| `Logger.swift` | `Log` enum: OSLog wrappers (app, http, session, network, setup categories) |
| `SpriteAssignment.swift` | Deterministic pet-per-project: stable hash of project name → built-in pet ID |

## HTTP API (port 1234)

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/status?pid=X&state=busy\|idle&type=task\|service&cwd=PATH` | GET | Session status update |
| `/heartbeat?pid=X&cwd=PATH` | GET | Keep session alive |
| `/visit` | POST | Incoming peer visit (JSON) |
| `/visit-end` | POST | Peer visit ended (JSON) |
| `/mcp/say` | POST | Speech bubble trigger (JSON) |
| `/mcp/react` | POST | Reaction animation trigger (JSON) |
| `/mcp/pet-status` | GET | Full status JSON for MCP |
| `/debug` | GET | Plain text state dump |

## Panel

The main UI is a snor-oh-style unified panel (`SnorOhPanelWindow` + `SnorOhPanelView`):
- **Header**: small animated mascot + "snor-oh" title + project count badge + overall status dot + collapse toggle
- **Project cards**: per-project rows with unique sprite avatar (via `SpriteAssignment`), status pill, duration, modified file count
- **Card interactions**: click opens VS Code, right-click context menu (VS Code / Terminal / Finder / copy path), hover shows close button
- **Speech bubble row**: appears inline below header when bubble is visible
- **Size tiers**: compact / regular / large (`SnorOhSize` enum, configurable in Settings)
- **Collapse**: header-only mode via chevron toggle, persisted in UserDefaults

## Key Constants

- Heartbeat timeout: 40s (pid 0 exempt)
- Service display: 2s then auto-revert to idle
- Idle to sleep: 120s
- Watchdog interval: 2s
- Shell heartbeat: 20s
- Default visit duration: 15s
- Animation: 80ms/frame (12.5 fps), auto-freeze after 10s on idle/disconnected
- Sprite sheets: 4 built-in characters (rottweiler/dalmatian 64px, samurai/hancock 128px)
- Display size: 128px base
- Peer discovery: Bonjour `_snor-oh._tcp`, TXT: nickname/pet/port
- NWListener uses ephemeral port (avoids conflict with HTTP server on :1234)
- Max visitors: 5, max visit duration: 60s

## Status Priority

`busy (4) > service (3) > idle (2) > visiting (1) > disconnected/searching/initializing (0)`

## Shell Hooks

Extended from snor-oh with `cwd` parameter for multi-session project identification:
- `Resources/Scripts/terminal-mirror.zsh`
- `Resources/Scripts/terminal-mirror.bash`
- `Resources/Scripts/terminal-mirror.fish`

## MCP Server

Reused from snor-oh: `Resources/Scripts/mcp-server/server.mjs`
- 3 tools: `pet_say`, `pet_react`, `pet_status`
- Bridges to HTTP :1234

## Custom Pets

- **Metadata**: `~/.snor-oh/custom-mimes.json` (JSON array of CustomMimeData)
- **Sprites**: `~/.snor-oh/custom-sprites/` (PNG files per status)
- **ID format**: `custom-<UUID>` (e.g., `custom-A1B2C3D4-...`)
- **Frame size**: Always 128px (grid-packed by SmartImport)
- **Files per mime**: 7 status PNGs + optional source sheet (`-source.png` for Smart Import)
- Custom pets identified by `pet.hasPrefix("custom-")`
- Built-in pets: rottweiler, dalmatian, samurai, hancock
- `.snoroh` export is lossy: does not include source sheet or frame inputs

### Smart Import Pipeline

```
Load PNG → detectBgColor (4-corner sampling) → removeBackground (alpha=0)
→ detectRows (horizontal gap scan) → detectColumns (3-pass: raw → bridge gaps → absorb slivers)
→ extractFrames → createStripFromFrames (tight bbox, scale to 128px, grid pack)
```

- Constants: BG_TOLERANCE=30, ALPHA_THRESHOLD=10, MIN_GAP=5, MIN_REGION_WIDTH=10
- Grid: MAX_SHEET_WIDTH=4096 (32 frames per row at 128px)
- Bitmap context uses `premultipliedLast` (background pixels are fully opaque so premultiplied == straight for comparison; transparent pixels set all 4 bytes to 0)
- Frame input parsing: "1-5" (range), "1,3,5" (list), "1-3,5,7-9" (mixed), 1-based

## Settings

- **General tab**: Theme, glow, bubbles, card size (compact/regular/large), auto-start (SMAppService), dock visibility, tray visibility
- **Mime tab**: Nickname, display scale (0.5x–2x), pet selection grid, import/export .snoroh
- **About tab**: Version from Bundle.main, dev mode (10-click secret), GitHub link
- **Persistence**: `@AppStorage` (UserDefaults) via `DefaultsKey` constants
- **PetCard**: Shows static first frame from SpriteCache (no running timer)
- **SettingsWindow**: NSWindowDelegate clears reference on close to free SwiftUI hosting views
- **SetupWizard**: Uses @Observable SetupModel class (not struct) for stable background async mutation

## Important Patterns

- **Timer pattern**: Always `Timer(timeInterval:...)` + `RunLoop.main.add(t, forMode: .common)` — never `Timer.scheduledTimer` + `RunLoop.main.add` (causes double-fire)
- **NSApp.setActivationPolicy**: Main-thread only; wrap in `DispatchQueue.main.async`
- **File I/O at launch**: `MCPInstaller.installServer()` + `ClaudeHooks.migrate()` run on background queue (not main thread)
- **Custom pet IDs**: `"custom-\(UUID().uuidString)"` — UUID for guaranteed uniqueness
- **Atomic writes**: `.atomic` option for Data.write, `replaceItemAt` for file replacement
- **MiniSpriteModel**: Reference-type `@Observable` class for per-card sprite animation (avoids struct-copy timer issues)

## Testing

- Unit tests: `Tests/SessionManagerTests.swift` (19 tests)
- Run: `swift test`
