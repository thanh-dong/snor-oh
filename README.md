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

**Panel** — Tamagotchi-style layout: mascot hero on top, collapsible session list below with status summary and per-project status rails.

**Mascot reactions** — The pet reacts to what's in the bucket. Inventory badge on the top-right shows the count (`99+` clamped). At 20 / 50 / 100 items the pet pops an "I'm heavy!" bubble — click it to open the bucket. Every item drop triggers a 400 ms orange tint flash, brighter when you drop directly onto the mascot. When Claude Code is idle and the bucket has items, the pet enters a dedicated `carrying` state with an orange status dot.

**Bucket** — Standalone floating shelf (`⌃⌥B` to toggle) for stashing anything during your day: files, URLs, images, text, colors. Drop onto the mascot or `⌘C` anything to add; drag items out of the bucket into any app to paste them. Items stay unique (re-adding promotes the existing item to the top instead of duplicating), with LRU eviction by count and disk size. Terminals and password managers are ignored by default so selected text and secrets are never captured.

**Quick Actions** — Right-click any bucket item → **Actions ▸**:
- **Resize image** (50 / 25 / 10 %) via ImageIO high-quality thumbnail
- **Convert** to PNG / JPEG / HEIC with per-format quality control
- **Strip metadata** — drops EXIF / GPS / TIFF / IPTC / XMP in one pass
- **Extract text** — on-device Vision OCR; writes back to the source and creates a text item next to it
- **Translate to…** — on-device Apple `Translation.framework` (macOS 15+), no API keys, no network

Derived items (resized photos, OCR'd text, translations) land right beside their source with a corner badge and "from *X*" secondary line, so you can see provenance at a glance. Right-click → **Reveal Source** scrolls back to the original with an accent outline pulse.

**Searchable screenshots** — Type in the bucket search field and every image gets OCR'd on demand, results returning in the same scroll view. Three indexing modes in Settings: Eager (OCR on add), Lazy (on first search — default), Manual (only when you click Extract text). Everything runs on-device.

**Quick Look** — Select any card and press **Space**. Files and images render natively; text / rich text / URL / color items are materialized into temp files so Quick Look can preview them too.

**Menu Bar** — Status icon shows colored dots with session counts, plus an orange dot for bucket-item count. Speech bubbles pop from the icon when the panel is hidden.

**Settings** — General (theme, glow, size, MCP install/uninstall), Ohh (pet selection, display scale, Smart Import, .snoroh export/import, marketplace upload), Bucket (clipboard capture, ignored apps, capacity, OCR indexing mode), Claude Code (plugin/skill/command/MCP/hook manager), About.

**Smart Import** — Upload any sprite sheet PNG, auto-detect frames (background removal, row/column detection), assign frame ranges per status, preview animations.

**Custom Pets** — Create unlimited custom pets via Smart Import or `.snoroh` file import. Stored at `~/.snor-oh/custom-ohhs.json` + `~/.snor-oh/custom-sprites/`. Share your pets with others or browse community submissions at the marketplace — see below.

**Marketplace** — [**snor-oh.vercel.app**](https://snor-oh.vercel.app) — browse and download community-submitted pets, or upload your own directly from **Settings → Ohh → Share to Marketplace**.

**Peer Discovery** — Finds other snor-oh instances on LAN via Bonjour. Visit peers — your mascot appears on their screen.

**Multi-Session** — Each terminal tracked by PID + working directory. Grouped into projects. Status priority: busy > service > carrying > idle > visiting > disconnected.

## Built-in Pets

| Pet | Source |
|-----|--------|
| Sprite | PMD-style, 12 animations (default) |
| Samurai | 128px sprite strips |
| Hancock | 128px sprite strips |

## Development

```bash
swift build && swift run    # build & run
swift test                  # 216 unit tests
bash Scripts/build-release.sh  # release .app → .build/release-app/snor-oh.app
```

Release notes live in `docs/releases/`. The feature roadmap and buddy-feature landscape are in `docs/prd/buddy-roadmap.md`.

## Inspired By

- **[ani-mime](https://github.com/vietnguyenhoangw/ani-mime)** by [@vietnguyenhoangw](https://github.com/vietnguyenhoangw) — The original Claude Code desktop mascot. ani-mime's architecture, sprite system, MCP integration, and peer discovery were the foundation snor-oh was built upon.

- **[floatify](https://github.com/HiepPP/floatify)** by [@HiepPP](https://github.com/HiepPP) — The floating panel and per-project session card design that shaped snor-oh's UI layout.

## License

MIT
