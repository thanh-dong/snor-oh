# snor-oh Buddy Roadmap

*Generated: 2026-04-21 · last refreshed 2026-04-22 at v0.8.0 ship — reference doc for "what to build next" decisions. Pick one bet at a time; mark items as you ship.*

North star: **snor-oh is the desktop buddy for a macOS user running Claude Code all day, who also has daily errands to juggle.** The mascot is the character moat; the bucket is the utility surface; everything else should feed one of those two stories.

---

## 1. Current state (verified against source, 2026-04-22 at v0.8.0)

### Shipped

- **Epic 01 Core Bucket MVP** — `BucketManager` (959 LOC), `BucketStore`, `BucketDropHandler`, `ClipboardMonitor`, `URLMetadataFetcher`, search UI in `BucketView`, mascot-as-drop-target wiring
- **Epic 02 Mascot Integration** — `.carrying` status (priority between idle and service), `BucketBadgeView` (top-trailing inventory badge), catch-flash overlay on `.bucketChanged.added` with mascot-origin boost, heavy-threshold bubbles at 20/50/100 with clear-and-refill reset, actionable `SpeechBubble` tap → opens bucket window
- **Epic 07 Quick Actions (Musts)** — `QuickAction` protocol + registry, `ResizeImageAction` (ImageIO thumbnail), `ConvertImageAction` (PNG/JPEG/HEIC), `StripExifAction`, `ExtractTextAction` (Vision OCR w/ writeback to `ocrText`), `OCRIndex` actor with bounded 4-way parallelism, OCR-powered search (`BucketManager.search` matches `item.ocrText` for image items), OCR indexing mode setting (eager/lazy/manual, default `.lazy`), `TranslateSheet` SwiftUI view (macOS 15+, Apple's on-device `Translation.framework`), per-card spinner overlay + red-bubble error surface
- **Epic 04 Multi-Bucket + Auto-Route** — tabs, create/delete, auto-route rules, `⌃⌥1–9` switcher
- **QuickPaste popup** (`⌘⇧V`) — closes the top two CopyClip-2 gaps (paste hotkey + search)
- **Core platform** — session awareness, HTTP :1425 server, MCP stdio server, Bonjour peer discovery, visitor system, Smart Import for custom sprites, setup wizard, Claude Code settings tab

### Planned but not shipped

| Epic | Tier | Effort | Status |
|---|---|---|---|
| 03 Screenshot Auto-Catch | 🟡 v1.1 | S (2–3d) | not started |
| 05 Bucket Peer Sync via Bonjour | 🟡 v2 | M (2w) | not started |
| 06 Notes + Snippets (TextExpander-lite) | 🟡 v1.1 | S–M (1w) | not started |
| 07 Quick Actions (stitch PDF, Compress ZIP, Rename) | 🔵 v1.2 | S (follow-up) | Musts shipped 2026-04-22; only Shoulds remain |
| 08 Power Features (expiry, Shortcuts, watched folders, URL scheme) | 🔵 v2 | L | not started |

### CopyClip-2 gap analysis items still open

- [ ] Plain-text paste modifier (hold `⌥` on drag-out)
- [ ] Source-app + paste-count tooltip on cards
- [ ] In-place text-clip editor
- [ ] Theme presets (~4 swatches)
- [ ] Clipboard stress test + `changeCount` audit
- [ ] 3-entry-point state-consistency audit (panel / mascot drop / Settings)

---

## 2. Recommendation for the next pick

Epic 02 and Epic 07 Musts landed in v0.8.0. The shortlist for what's next, sized for a single sprint each:

| Option | Effort | Unlocks | Risk |
|---|---|---|---|
| **Epic 03 Screenshot Auto-Catch** | S (2–3d) | Dropover-parity "it just works" demo moment | Low — FSEvents + Full Disk Access caveat |
| **Epic 06 Notes + Snippets** | S–M (1w) | Kills a TextExpander subscription; `⌃⌥N` / `⌃⌥V` | AX permission for snippet expansion |
| **Epic 07 follow-ups** (Compress ZIP, Stitch PDF, Rename, multi-select) | S (follow-up) | Finishes the Dropover parity story | Very low — action protocol already exists |
| **A1 Task completion coach** | S (1–2d) | First "buddy" feature — pet celebrates Claude `Done`, mopes on `Failed` | Very low — reuses Epic 02 actionable-bubble infra |
| **Epic 05 Peer Sync** | M (2w) | LAN moat | HTTP auth surface, 50 MB transfers |
| **Epic 08 Power Features** | L (3w) | Shortcuts + watched folders + URL scheme | Schema additive but UI is big |

**Lean**: **Epic 07 follow-ups → A1 Task completion coach**. Follow-ups are 2–3 days of mechanical wins that polish what just shipped. A1 is a genuine new moat — turns snor-oh from "cute Dropover" into "Claude Code buddy" — and the infra is already in place.

**Suggested cadence:** v0.8.1 = Epic 07 follow-ups + `A1` → v0.9 = Epic 03 + Epic 06 → v1.0 = Epic 05 + Epic 08.

---

## 3. Buddy feature landscape

Ideas that fit the mascot-character conceit — where having a pet that reacts adds value over a plain menu-bar widget. Group by theme; pick one theme per sprint so the product identity stays coherent.

### A. Deeper Claude Code integration (existing moat)

| ID | Feature | Why it fits | Effort |
|---|---|---|---|
| A1 | **Task completion coach** — pet celebrates `Done`, mopes on `Failed`, offers "run tests?" bubble | Status events via HTTP :1425 already flow | S |
| A2 | **Plan-mode visualizer** — show ordered plan steps as sticky notes above pet; strike through as each completes | Makes long autonomous runs glanceable | M |
| A3 | **Token budget pet-mood** — pet sleepier as context fills; wakes after `/clear`. Opus vs Sonnet as coin icons | Makes invisible cost visible | M |
| A4 | **Error-to-bucket** — failed commands / build errors auto-drop into a "Claude Code errors" bucket with stack trace + timestamp | Reuses Epic 01; transient → searchable | S |
| A5 | **Hook / skill marketplace** — extend `marketplace/` to one-click install community skills/hooks/snippets | Network effect, existing dir | M |
| A6 | **Session transcript bucket** — drop a session ID onto pet → pulls transcript into a note | Leverages `SessionManager` | S |
| A7 | **PR / commit celebration** — detect `git commit` / `gh pr create` in session, pet throws confetti | Hooks already trigger sprites | S |
| A8 | **Autonomous-loop babysitter** — while a `/loop` agent runs in the background, pet shows heartbeat + lets you pause/kill from the panel | Fills a real gap in long-running agents | M |
| A9 | **[Away digest](A9-away-digest.md)** — real user-idle detection → per-project tooltip + one-shot welcome-back bubble summarizing what each session did while you were gone. Uses only own data (no `awaySummaryEnabled` dep) | Multi-session triage in <5s; no terminal-cycling | S |

### B. Daily-errand helpers (new territory)

| ID | Feature | Why it fits | Effort |
|---|---|---|---|
| B1 | **Calendar/Reminders bubbles** — pet surfaces next event as speech bubble; drag bubble → bucket to pin | EventKit; mascot = glanceable calendar | M |
| B2 | **Focus / Pomodoro companion** — pet switches to "focused" sprite; bucket auto-route pauses; timer in bubble | Existing sprite system | S |
| B3 | **Shortcuts recipe library** — curated Shortcuts (send to iPhone, set Slack status, "remind me tomorrow") launchable from pet | Lands on Epic 08's AppIntents | M |
| B4 | **Daily wrap-up** — end-of-day pet summarizes: N items bucketed, N sessions, top 3 apps. Drag summary → Notes/Journal | Local-only, no LLM | S |
| B5 | **Send to iPhone** — right-click bucket item → AirDrop; pet animates carrying item "off-screen" | No iCloud needed | S |
| B6 | **Ambient info bubbles** — weather / battery / next meeting in-between Claude sessions | Ambient companion mode | S |
| B7 | **Inbox triage bucket** — drop a Mail message URL on pet → tracked with "reply by EOD"; nags at 4pm | EventKit + Mail URL scheme | M |
| B8 | **Screen recording bucket** — "record last 5s" á la NVIDIA Highlights, drops MP4 into bucket | ScreenCaptureKit | M |
| B9 | **System-tidy coach** — pet surfaces "you have 47 files on Desktop" weekly and offers one-click archive to bucket | FSEvents on Desktop | S |

### C. Mascot-first differentiators (character moat)

| ID | Feature | Why it fits | Effort |
|---|---|---|---|
| C1 | **Emotion state machine** — hungry (empty bucket long), heavy (>100 items), bored (no sessions), excited (task done). Feeds sprite picker | Extends status enum | S |
| C2 | **Pet care interactions** — click to pet/feed; ties into Pomodoro breaks; streaks unlock skins | Gamification retention loop | M |
| C3 | **Peer "visits" with gifts** — visitors bring shared bucket items and leave a note | Builds on `VisitManager` | S |
| C4 | **Pet narration diary** — template-based daily journal of your day, exportable markdown | Offline, privacy-first | S |
| C5 | **Animation packs** — extend Smart Import to a full reaction GIF pack | Existing flow | M |
| C6 | **Personality settings** — cheerful / chill / stoic — tunes bubble frequency + phrasing | Low code, high delight | S |

### D. Platform / distribution

| ID | Feature | Why it fits | Effort |
|---|---|---|---|
| D1 | **Homebrew tap** | In progress per last session | — |
| D2 | **Raycast/Alfred extensions** — search buckets, trigger auto-route | Tiny surface, daily users | S |
| D3 | **iOS companion via Bonjour Handoff** | Extends peer sync, no backend | L |
| D4 | **Marketplace v2** — community sprites, hook packs, snippet packs | Network effect | L |
| D5 | **Signed + notarized distributable** | Already identified as pain | S–M |

---

## 4. Decision framework for "which bet next?"

Three archetypes — pick the one that matches current energy, ship it, then reassess.

1. **Consolidation bet** — Epic 02 → Epic 03 → CopyClip polish. Low risk, completes the bucket story. Best if you want the v1 product to feel finished before branching.
2. **Buddy bet** — Epic 02 + A1 (task coach) + B2 (Pomodoro). Reframes snor-oh from "cute utility" to "companion." Medium effort, biggest narrative shift.
3. **Platform bet** — Epic 05 Peer Sync + D4 Marketplace v2. Goes wide before it goes deep. Highest moat, highest risk.

**Lean:** option 1 → option 2. Epic 02 is a no-regret foundation; once it ships, A1/A4/B2 become 1–2 day adds because they're all `@Observable` observers on existing notifications.

---

## 5. Things we explicitly will not build

Locked in from earlier research, re-stated so they don't accidentally sneak into future sprints.

- Cloud account / hosted sync (Bonjour only)
- AES-256 encryption of bucket storage (macOS sandbox suffices)
- AI / OCR / summarization as core features (opt-in per-action only, Epic 07)
- Paste sequences / queue (Pastebot's niche)
- Cross-platform port (macOS only)
- Matching CopyClip's 9,999-item history (buckets are staging, not archives)

---

## 6. How to use this doc

- Each item in §3 is a feature ID (A1, B2, …). When you pick one, write a focused PRD at `docs/prd/<feature-id>-<slug>.md` following the existing bucket PRD format (problem / hypothesis / MoSCoW / acceptance / rollout).
- Cross-cutting decisions (hotkey table, notification contract, sentinel convention) go back into `docs/prd/bucket/README.md` — that's already the source of truth.
- When an epic ships, mark it in §1 "shipped" and remove from "planned."
