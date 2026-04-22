# Epic 02 — Mascot Integration

**Tier**: 🟢 v1 blocker · **Complexity**: S (1 week) · **Depends on**: Epic 01

## Problem Statement

Every competitor bucket app (Dropover, Yoink, Unclutter, Droppy) has the same silhouette — a neutral glass rectangle holding thumbnails. snor-oh already ships a character-driven mascot that users are emotionally attached to; without wiring the bucket into the pet, we're leaving our single unfair advantage on the floor ([research §Recommendation](../../research/bucket-feature-research.md#4-recommendation-for-snor-oh-bucket)). The pet needs to *physically* acknowledge the bucket's contents so users feel their stash is in the care of something alive.

**Note on split with Epic 01**: the mascot already accepts drops in Epic 01 (same `BucketDropHandler` as the panel). This epic adds the *visual reactions* that make the drop feel alive — the catch animation, inventory badge, and overflow speech bubbles.

## Hypothesis

> We believe **mascot-aware bucket feedback (carrying animation, count badge, overflow speech bubble)** will turn the bucket from a utility into a ritual — driving users to interact with snor-oh more often *and* making them less likely to forget items in the bucket. We'll know we're right when users who see the "I'm heavy!" bubble clear the bucket within 60 seconds >50% of the time.

## Scope (MoSCoW)

| Priority | Capability | Why |
|---|---|---|
| Must | Inventory badge on mascot (small bubble showing item count when >0) | Minimum mascot-bucket linkage |
| Must | New mascot status: `carrying` — triggered when bucket has ≥1 item AND mascot is idle | Visible proof the pet is holding stuff |
| Must | "I'm heavy!" speech bubble at thresholds (20, 50, 100 items) using existing `BubbleManager` | Forcing function to clean up |
| Must | Sprite reaction animation when an item is added via *any* drop surface (one-frame "catch" blink + tint flash) | Discoverability — closes the loop on the drop Epic 01 plumbed |
| Could | Per-pet carry pose (sprite pet has a "holding" pose vs samurai has its own) | Theming depth |
| Won't | Bespoke sprite artwork for every pet's "carrying" state in v1 | Art cost — reuse idle pose + badge overlay |
| Won't | Wire `MascotView.onDrop` (moved to Epic 01) | Drop target pipe is a Must for MVP, not a mascot-only feature |
| Won't | Menu-bar icon count (owned by Epic 01) | Avoid duplication |

## Users & Job-to-Be-Done

**Primary**: Same as Epic 01 — the existing snor-oh user.

**JTBD**: *When I've stashed something in the bucket, I want the pet to acknowledge it so the bucket feels alive and I remember it exists.*

## User Stories

1. When I drop a file onto the mascot (Epic 01 routing), I see the pet "catch" it (single-frame animation) and a small "1" appears on the mascot.
2. After stashing 20 items over a morning, snor-oh pops a speech bubble: "I'm carrying 20 things — want help organizing?" which opens the bucket panel on click.
3. While working I glance at the mascot and its carrying pose + badge reminds me that I still have unfiled items.
4. When the bucket is empty, the pet returns to its normal idle animation — no nagging, no guilt.

## UX Flow

```
Bucket empty                   Bucket has 3 items              Bucket has 23 items
┌─────────────┐              ┌─────────────┐                ┌─────────────┐
│  🐱 idle    │              │  🐱 idle    │                │  🐱 idle    │
│             │              │       ②3①   │                │       ②3①   │
│ "..."       │   drop →     │ "*catch*"   │   drop 20x →   │ "I'm heavy!"│
└─────────────┘              └─────────────┘                │             │
                                                             │   (opens    │
                                                             │   bucket)   │
                                                             └─────────────┘
```

**Catch reaction path**: The drop target is already wired in Epic 01. This epic listens to `.bucketChanged` (with an `added` payload hint) and plays the catch animation + tint flash when the source was the mascot. The mascot doesn't *move* — the items fly into it visually and land in the bucket. This is the hero interaction and should feel magical.

## Acceptance Criteria

- [ ] On successful drop (from *any* surface — mascot, panel, Cmd-C, Epic 03 screenshot, Epic 04 auto-route), mascot plays one "catch" frame for 400 ms then returns to current state
- [ ] When the drop source is the mascot itself, play an extra "tint flash" overlay for emphasis
- [ ] Inventory badge: appears when `activeBucket.items.count > 0`, hides at 0, shows `99+` above 99
- [ ] Badge positioned at top-right of mascot sprite, scales with `displayScale` setting
- [ ] Speech bubble thresholds: 20, 50, 100. Each threshold fires at most once per session.
- [ ] Clicking the "I'm heavy!" bubble opens the bucket tab of the panel
- [ ] Badge + bubble react to `.bucketChanged` notification — no polling
- [ ] `.carrying` status is active only when no higher-priority status (busy/service) is active
- [ ] Does not steal focus or interrupt any existing bubble/animation

## Data Model

No new persistent types. Runtime additions only:

```swift
// Sources/Core/Types.swift — extend existing Status enum

public enum Status: Int, Codable, Sendable {
    case disconnected, searching, initializing, idle, service, busy, visiting
    case carrying                              // NEW — priority between idle and busy
}
```

```swift
// Sources/Sprites/SpriteConfig.swift — extend

public struct SpriteSheetInfo {
    // existing fields...
    public var carryingSheet: String?          // optional per-pet carry animation; fall back to idle+badge
}
```

```swift
// Sources/Views/MascotView.swift — extend
// Note: .onDrop wiring is added in Epic 01. This epic adds only the overlay.

struct MascotView: View {
    // existing body ...
    .overlay(alignment: .topTrailing) { BucketBadgeView() }
    .onReceive(NotificationCenter.default.publisher(for: .bucketChanged)) { note in
        spriteEngine.playCatchReaction(source: note.userInfo?["source"] as? String)
    }
}
```

**Notification contract (shared with Epic 01)**: `.bucketChanged` payload should include a `source` key (`"mascot" | "panel" | "clipboard" | "screenshot" | "peer" | "watched-folder" | "shortcut"`) so Epic 02 can pick the right reaction intensity. Epic 01 sets this on every add — treat it as part of the Epic 01 acceptance.

## Implementation Notes

| Concern | Fit |
|---|---|
| Status priority | Update existing priority constant: `busy (5) > service (4) > idle (3) > carrying (2.5) > visiting (2) > …`. Carry only shows when no higher-priority status is active. |
| Catch animation | Reuse `SpriteEngine.playOnce(frames:)` with a one-shot frame. No new sprite assets required — tint flash overlay on top of idle frame is acceptable for v1. |
| Badge renderer | New `BucketBadgeView` SwiftUI — a `Capsule().fill(.orange).overlay(Text(count))` pinned to mascot corner. Orange matches existing menu-bar dot palette. |
| Speech bubble | Existing `BubbleManager.post(message:, dismissAfter:)`. Threshold bookkeeping in `BucketManager.bubbledThresholds: Set<Int>` (in-memory, resets per launch). |
| Menu bar | **Owned by Epic 01**. This epic does not touch the menu bar. |
| Drop target | **Owned by Epic 01**. `MascotView.onDrop` wiring lives there. This epic only reacts to `.bucketChanged`. |

**Concurrency**: All UI updates on `@MainActor`. `NotificationCenter` observers bounced through `MainActor.run`.

## Out of Scope

- Unique "carrying" sprite sheets per pet — use badge overlay for v1, add per-pet art later
- Item-specific animations (different pose when holding an image vs a file) — not worth the art cost
- Any audio feedback — snor-oh is silent today, keep it silent
- Haptic feedback on Magic Trackpad — macOS API is finicky, defer

## Open Questions

- [ ] Should the badge be hidden when the panel is open (the user can already see the count)?
- [ ] Is the "I'm heavy!" threshold list (20/50/100) right, or should it be ratio-based against `maxItems`?
- [ ] Should the catch animation interrupt a `busy` Claude Code animation, or defer?
- [ ] Does dropping onto mascot while the bucket panel is hidden auto-show the panel briefly? (Lean: yes, 2s preview)

## Rollout Plan

| # | Task | Files | Done |
|---|------|-------|------|
| 1 | Add `.carrying` status + priority update | `Core/Types.swift`, `Core/SessionManager.swift` | ✅ |
| 2 | `BucketBadgeView` SwiftUI overlay | `Views/BucketBadgeView.swift` | ✅ |
| 3 | `.bucketChanged` observer on `MascotView` + invoke catch reaction | `Views/MascotView.swift` | ✅ |
| 4 | "Catch" one-shot sprite frame + tint flash | `Animation/SpriteEngine.swift` | ✅ |
| 5 | Speech bubble threshold triggers | `Core/BucketManager.swift`, `Views/SpeechBubble.swift` | ✅ |
| 6 | Manual verification against existing visitor/busy animations (no regressions) | – | ✅ |
| 7 | Release build verify | – | ✅ |

## Success Metrics

| Metric | Target | Method |
|---|---|---|
| % of users who see "I'm heavy!" bubble and clear bucket within 60s | >50% | Time-delta between bubble post and `clearUnpinned` call |
| Drop-onto-mascot as % of all drops | >30% | Drop-source counter (`panel` vs `mascot`) |
| Session length change vs v1 baseline | +0% (no regression) | Watchdog session length |
