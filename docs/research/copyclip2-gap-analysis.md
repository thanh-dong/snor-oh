# CopyClip 2 vs snor-oh Bucket — gap analysis

_Source: [CopyClip 2 on the Mac App Store](https://apps.apple.com/us/app/copyclip-2-clipboard-manager/id1020812363?mt=12), fetched 2026-04-20_

CopyClip 2 is a **$7.99 text-only clipboard history** by FIPLAB Ltd with 10 years of iteration (v1 2016 → v3.991 April 2026). snor-oh's Bucket is a **multi-kind staging area** with multi-bucket contexts and drag-out. Different products, but they collide on the "where did my ⌘C go?" daily workflow. This doc catalogs where CopyClip is ahead, what's worth stealing, and what risks their negative reviews reveal for us.

---

## Feature matrix

| Capability | CopyClip 2 | snor-oh Bucket |
|---|---|---|
| Text clips | ✅ up to 9,999 | ✅ default 200, max 250/bucket |
| File / folder clips | ❌ | ✅ |
| Image clips (screenshots, pasteboard images) | ❌ | ✅ with sidecar storage |
| URL clips with favicon + og:image | ❌ | ✅ |
| Color clips | ❌ | ✅ |
| Persistent history | ✅ | ✅ |
| Dedupe on re-copy | ✅ (promote to top) | ✅ (path / hash / text equality) |
| Pin items | ✅ `⇧⌘P` | ✅ |
| App exclusion (Terminal, password mgrs) | ✅ | ✅ seeded defaults |
| Search across history | ✅ instant filter | ⚠️ `search()` in manager, **no UI** |
| In-place edit of clip text | ✅ | ❌ |
| Paste as plain text toggle | ✅ | ❌ |
| Quick paste `⌘1–9` | ✅ | ❌ (we have `⌃⌥1–9` for **bucket switch**, not paste) |
| Rebindable shortcuts | ✅ | ❌ hard-coded |
| Source-app tooltip on hover | ✅ | ⚠️ data stored, not surfaced |
| Paste-count tooltip | ✅ | ❌ |
| Themes | ✅ 10+ | ❌ inherits macOS light/dark |
| Drag items **out** into target apps | ❌ (paste only) | ✅ |
| Drag items **in** / drop onto mascot | ❌ | ✅ |
| Multi-bucket contexts with tabs | ❌ single shelf | ✅ |
| Auto-route by app / kind / URL host | ❌ (only exclusion) | ✅ |
| Peer sync (Bonjour) | ❌ | ✅ |
| Screenshot + mixed-media sidecar storage | ❌ | ✅ |
| Mascot + terminal-session companion | ❌ | ✅ orthogonal surface |

---

## Gaps where CopyClip wins (ranked by user-visible impact)

### 1. Instant paste hotkeys — `⌘1` through `⌘0`
**CopyClip**: press `⌘5` and the 5th-most-recent clip lands at the cursor.
**snor-oh**: you have to open the panel and drag out. Our `⌃⌥1–9` switches *buckets*, not pastes items.
**Impact**: biggest daily-use delta. Drag-out is unambiguously slower than one keystroke.
**Effort**: medium — plumb synthetic keystroke emission (CGEventPost or NSPasteboard + paste sim) through the existing drag-out code path. ~2 days.

### 2. Search UI
**CopyClip**: type in the history window and the list filters instantly.
**snor-oh**: `BucketManager.search(_:)` is a documented helper but no view surfaces it.
**Impact**: users with >30 items in a bucket can't find anything. Becomes painful past 50.
**Effort**: small — `/` or `⌘F` focus + `TextField` above the item list, reusing `search()`. ~1 day.

### 3. Paste as plain text modifier
**CopyClip**: option to strip formatting at paste time.
**snor-oh**: rich text is preserved verbatim; pasting a Notion clip into Slack includes styling users usually don't want.
**Impact**: a staple clipboard-manager feature; users notice its absence when moving from Pastebot / Paste / CopyClip.
**Effort**: small — hold `⌥` during drag-out → strip to `.string` on the pasteboard write. ~0.5 day.

### 4. Source app + paste count on card tooltip
**CopyClip**: hover any clip, see source app icon and N-times-pasted counter.
**snor-oh**: we already store `sourceBundleID` on every `BucketItem`. Paste count isn't tracked but is a 3-line addition to `BucketItem` + mutation in the paste path.
**Impact**: low friction feature, high polish signal.
**Effort**: small — 0.5 day for source, +0.5 day for paste count including migration.

### 5. In-place text edit
**CopyClip**: double-click a text clip → edit → save.
**snor-oh**: no editor.
**Impact**: common use case — "clip this boilerplate, fix the typo, paste". Today users have to paste into a scratch app, edit, re-copy.
**Effort**: small — SwiftUI `TextEditor` sheet from the card context menu. ~0.5 day.

### 6. Rebindable shortcuts
**CopyClip**: shortcuts are customizable; a negative review specifically calls out conflicts with other extensions.
**snor-oh**: `⌃⌥B` panel toggle and `⌃⌥1–9` bucket switch are hard-coded via `HotkeyRegistrar`. Likely conflicts with Chrome tab-switching (`⌘1–9`), iTerm2, Karabiner, Raycast, Alfred.
**Impact**: blocking issue for a small slice of power users; friction for the rest.
**Effort**: medium — hotkey-picker UI in Settings + dynamic re-register on change. ~1 day. Can use the existing `HotkeyBinding` type.

### 7. Themes
**CopyClip**: 10+ named themes (Dark, Light, Lavender, Graphite, Ocean, Rose, Slate).
**snor-oh**: system light/dark only.
**Impact**: low, but it's a retention touch — users personalize a panel they see hundreds of times a day.
**Effort**: medium-low — theming surface on the panel + mascot tint. ~1 day if kept to ~4 presets.

### 8. High item cap (9,999)
**CopyClip**: can archive a whole day's typing.
**snor-oh**: defaults to 200/bucket with a 250 UI max.
**Impact**: intentional philosophical difference — buckets are staging, not archives. Not a gap to close; instead, document the philosophy so users don't file it as a bug.

---

## Risk areas from CopyClip's negative reviews

### "Consistently misses copies" (top-voted negative review, sjwi223, 2023-05)

> "Frequent missed copies during rapid sequential actions... inconsistent behavior between two history interfaces."

This is the exact failure mode snor-oh is also at risk of. Our `ClipboardMonitor` polls on an interval (the Epic 01 cadence around 500ms). If three `⌘C` events happen inside one tick, only the final pasteboard state is captured unless we check `NSPasteboard.general.changeCount` on every tick and fire once per delta.

**Action**: write a stress test that hammers `⌘C` programmatically (or via AppleScript/`osascript`) and verifies every distinct copy is captured. If the test reveals drops, switch to a changeCount-delta poll with a tighter interval.

### "Inconsistent UI across entry points" (sjwi223)

> "ctrl+space vs ctrl+shift+space behave differently... window positioning unpredictability."

snor-oh has **three** entry points into bucket state: the floating panel, the mascot drop halo, and Settings → Buckets. Any drift between what they display (item counts, active bucket, sort order, archived-vs-active filtering) becomes a trust bug very fast.

**Action**: one integration pass to verify all three surfaces read from the same `@Observable` state and render the same data on the same change. Checklist:
- Active-bucket indicator consistent across panel pill, mascot color, Settings row.
- Item count tooltips match between panel header and Settings rows.
- Archive/restore fires `bucketChanged` that all three surfaces observe.

---

## Where snor-oh is already ahead of CopyClip

1. **Any-kind items** — files, folders, images, URLs with enriched metadata, colors. CopyClip is text-only.
2. **Drag-out** — drag a clip card into any target app to paste. CopyClip has no drag-out.
3. **Multi-bucket contexts** — named per-project shelves with auto-route rules. CopyClip is one shelf.
4. **Mascot companion** — orthogonal product surface for terminal / Claude Code session awareness.
5. **Peer sync via Bonjour** — send to other snor-oh instances on the LAN.
6. **Auto-route rules** — `RouteCondition` enum (frontmost app / kind / source app / URL host). CopyClip can only exclude.

---

## Recommended next moves (ranked by ROI)

| # | Change | Est. effort | User impact |
|---|---|---|---|
| 1 | Panel search (`/` or `⌘F` filter input) | 1 day | High |
| 2 | `⌥⌘1–9` pastes Nth item of active bucket into previously-frontmost app | 2 days | High |
| 3 | Plain-text paste modifier (hold `⌥` on drag-out) | 0.5 day | Medium |
| 4 | Source-app + paste-count on card tooltip | 1 day | Medium (polish) |
| 5 | In-place text-clip editor | 0.5 day | Medium |
| 6 | Rebindable hotkeys in Settings | 1 day | Medium (unblocks power users) |
| 7 | Clipboard-drop stress test + changeCount fix if needed | 0.5 day audit, up to 1 day to fix | High (reliability) |
| 8 | 3-entry-point state-consistency audit | 0.5 day | High (reliability) |
| 9 | Theme presets (~4) | 1 day | Low-Medium |

Items 1–4 + 7 close ~70% of the CopyClip workflow gap. Budget: one sprint (~1 engineer-week).

---

## Out of scope / non-goals

- Matching CopyClip's 9,999-item cap. Buckets are staging, not archives.
- Competing on price ($7.99). snor-oh is free and the mascot + terminal-session story is the differentiator.
- Porting CopyClip's themes 1:1 — 10+ themes is overkill for a panel users open briefly.
- Matching CopyClip's feature-for-feature UI. Drag-out + mixed-kind items mean our panel is structurally different; we're not rebuilding a menu-bar dropdown.
