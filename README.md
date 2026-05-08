# snor-oh

A native macOS desktop mascot that reacts to your terminal and [Claude Code](https://docs.anthropic.com/en/docs/claude-code) activity. Built with SwiftUI + SwiftNIO.

Your mascot floats on screen — running commands makes it busy, finishing tasks triggers a celebration, and idle time puts it to sleep. When the panel is hidden, status shows in the menu bar with bubble notifications.

## Requirements

- macOS 14.0 (Sonoma) or later
- [Node.js](https://nodejs.org/) for Claude Code MCP integration
- Swift 5.9+ (building from source only)

## Install

### From Release

Download the latest DMG from [Releases](https://github.com/thanh-dong/snor-oh/releases), drag to Applications. On first launch, if macOS blocks the app (ad-hoc signed):

```bash
xattr -cr /Applications/snor-oh.app
```

Then open normally. The setup wizard configures everything on first run.

### From Source

```bash
git clone https://github.com/thanh-dong/snor-oh.git
cd snor-oh
swift build && swift run          # dev
bash Scripts/build-release.sh     # release → .build/release-app/snor-oh.app
```

## Shell Integration

Source the hook script in your shell config to make the mascot react to terminal commands:

```bash
# Zsh (~/.zshrc)
source /Applications/snor-oh.app/Contents/Resources/Scripts/terminal-mirror.zsh

# Bash (~/.bashrc)
source /Applications/snor-oh.app/Contents/Resources/Scripts/terminal-mirror.bash

# Fish (~/.config/fish/config.fish)
source /Applications/snor-oh.app/Contents/Resources/Scripts/terminal-mirror.fish
```

## Claude Code Integration

**MCP Server** — Claude Code talks to the mascot via 3 tools: `pet_say` (speech bubble), `pet_react` (animation), `pet_status` (status query). Install/manage from Settings > General.

**Hooks** — Claude Code activity (tool use, prompts, session start/end) triggers mascot status changes automatically.

## Features

### 🪣 The Bucket — snor-oh's headline feature

A standalone floating shelf (`⌃⌥B` to toggle) that stashes **anything** you touch during a coding day: files, URLs, images, screenshots, text snippets, color swatches. The mascot *carries* it for you.

**How it fills up**
- **Drop onto the mascot** — any draggable content from Finder, browsers, or other apps
- **`⌘C` anywhere** — configurable ignore-list skips terminals + password managers so selected text and secrets are never captured
- **Unique items** — re-adding an existing item promotes it to the top instead of duplicating; LRU eviction by count and disk size keeps things tidy
- **Multiple buckets** — named lanes with auto-routing rules (file type, source app, URL host) and per-bucket opacity/contrast

**What you can do to an item** (right-click → **Actions ▸**)
- **Resize image** (50 / 25 / 10 %) — ImageIO high-quality thumbnail
- **Convert** to PNG / JPEG / HEIC with per-format quality
- **Strip metadata** — EXIF / GPS / TIFF / IPTC / XMP dropped in one pass
- **Extract text** — Vision OCR, on-device, writes back to source *and* creates a text item next to it
- **Translate to…** — Apple `Translation.framework` (macOS 15+), on-device, no API keys, no network

Derived items (resized photos, OCR'd text, translations) land **right beside their source** with a corner badge and "from *X*" secondary line — provenance at a glance. Right-click → **Reveal Source** scrolls back to the original with an accent outline pulse.

**Searchable screenshots** — type any word in the bucket search field and every image gets OCR'd on demand, results returning in the same scroll view. Three indexing modes: Eager (OCR on add), Lazy (on first search — default), Manual (only when you click Extract text). Everything runs on-device.

**Quick Look** — select any card and press **Space**. Files and images render natively; text / rich text / URL / color items are materialized into temp files so Quick Look can preview them too.

**Quality-of-life** — drag-to-reorder, auto-collapse when you focus another app, per-card thumbnail cache, draggable header, bucket badge on the menu bar icon (orange dot with item count).

### 🐾 Mascot & Sessions

**Mascot reactions** — the pet reacts to what's in the bucket. Inventory badge on the top-right shows the count (`99+` clamped). At 20 / 50 / 100 items the pet pops an "I'm heavy!" bubble — click it to open the bucket. Every item drop triggers a 400 ms orange tint flash, brighter when you drop directly onto the mascot. When Claude Code is idle and the bucket has items, the pet enters a dedicated `carrying` state with an orange status dot.

**Panel** — Tamagotchi-style layout: mascot hero on top, collapsible session list below with status summary and per-project status rails.

**Multi-Session** — each terminal tracked by PID + working directory, grouped into projects. Status priority: busy > service > carrying > idle > visiting > disconnected.

**Welcome-back digest** — step away from the keyboard, come back, and the mascot pops a per-project summary of file changes that happened while you were gone. Idle detection uses system input-idle + hysteresis; threshold and toggle live in **Settings → General**. Hover a project row for the full digest tooltip; right-click → *Clear digest* to dismiss.

**Menu Bar** — status icon shows colored dots with session counts, plus an orange dot for bucket-item count. Speech bubbles pop from the icon when the panel is hidden.

**Quick Paste** — `⌘⇧V` opens a recent-items panel; pick one and it pastes into your focused app.

### 🎨 Pets & Community

**Smart Import** — upload any sprite sheet PNG, auto-detect frames (background removal with halo + edge cleanup, row/column detection), assign frame ranges per status, preview animations.

**Custom Pets** — unlimited custom pets via Smart Import or `.snoroh` file import. Stored at `~/.snor-oh/custom-ohhs.json` + `~/.snor-oh/custom-sprites/`.

### ⚙️ Settings tabs

**General** (theme, glow, size, MCP install/uninstall, welcome-back toggle + threshold) · **Ohh** (pet selection, display scale, Smart Import, .snoroh export/import, marketplace upload) · **Bucket** (clipboard capture, ignored apps, capacity, OCR indexing mode, per-bucket routing rules) · **Claude Code** (plugin/skill/command/MCP/hook manager) · **About**.

## Built-in Pets

| Pet | Source |
|-----|--------|
| Sprite | PMD-style, 12 animations (default) |
| Samurai | 128px sprite strips |
| Hancock | 128px sprite strips |

## Development

```bash
swift build && swift run    # build & run
swift test                  # unit tests
bash Scripts/build-release.sh  # release .app → .build/release-app/snor-oh.app
```

Release notes live in `docs/releases/`. The feature roadmap and buddy-feature landscape are in `docs/prd/buddy-roadmap.md`.

## Inspired By

- **[ani-mime](https://github.com/vietnguyenhoangw/ani-mime)** by [@vietnguyenhoangw](https://github.com/vietnguyenhoangw) — The original Claude Code desktop mascot. ani-mime's architecture, sprite system, MCP integration, and peer discovery were the foundation snor-oh was built upon.

- **[floatify](https://github.com/HiepPP/floatify)** by [@HiepPP](https://github.com/HiepPP) — The floating panel and per-project session card design that shaped snor-oh's UI layout.

## License

MIT
