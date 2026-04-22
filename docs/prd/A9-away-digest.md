# A9 — Away Digest

**Tier**: 🟡 v1.1 buddy feature · **Complexity**: S (3–4 days, Approach C v1) · **Depends on**: none (additive on existing `SessionManager` + `Watchdog` + `BubbleManager`)

## Problem Statement

Users run snor-oh with multiple Claude Code sessions across several projects at once. When they step away for lunch, a meeting, or a long break, they come back to a cluster of terminals and no quick way to tell what each session did. Claude Code's own `awaySummaryEnabled` / `CLAUDE_CODE_ENABLE_AWAY_SUMMARY` feature is per-session, in-TUI only, and currently marked `@internal` — it can't be reliably consumed from outside, and it doesn't aggregate across sessions even if it could.

snor-oh already owns all the data needed to answer "what happened while I was away, per project": busy→idle transitions, task durations, git status deltas, session lifecycle events. The mascot panel is also already the glanceable home for cross-project state. The missing piece is a per-project digest that accumulates during a real user-away window and surfaces on return, without any dependency on upstream experimental flags.

## Hypothesis

> We believe **a passive tooltip on each project row plus a one-shot welcome-back bubble** will let users triage multi-session work after a break in under 5 seconds, without waking terminals. We'll know we're right when ≥40% of users who return to a non-empty digest click through to at least one project (tooltip hover or row tap) within 30 seconds of the welcome-back bubble.

## Scope (MoSCoW)

| Priority | Capability | Why |
|---|---|---|
| Must | Detect real user-away via `CGEventSourceSecondsSinceLastEventType`, threshold configurable (default 10 min) | Correct trigger — matches "I walked away" mental model |
| Must | Per-project event accumulation during away window (tasks, durations, file deltas) | Core data product |
| Must | Native `.help()` tooltip on each project row showing digest summary | Passive, user-seeks surface |
| Must | Welcome-back speech bubble on return if any digest is non-empty | Proactive surface, "buddy" moment |
| Must | Feature on/off toggle in Settings → General, live-effective | User control, privacy-of-attention |
| Must | Threshold slider (3–60 min) in Settings → General | Users who find it chatty/sparse can tune |
| Must | Right-click project row → "Clear digest" | Manual reset escape hatch |
| Should | Digest data model stores individual timestamped events (not just counters) | Forward-compat with Approach B rich popover in a future iteration |
| Could | Tooltip shows away-window range (e.g. "12:05–13:30") | Anchors the summary in time |
| Won't (v1) | Custom hover popover with rich formatting/chips | Deferred to a v2 (Approach B); ship detection + tooltip first, validate usage |
| Won't | Cross-device / peer digest aggregation | Bonjour peer state isn't reliable enough for claims about what they did |
| Won't | Integration with Claude Code's `awaySummaryEnabled` | Internal flag, no emission surface; revisit when Anthropic ships a hook/MCP event |
| Won't | Persisting digests across app relaunch | Away state is ephemeral; a relaunch starts fresh |

## Users & Job-to-Be-Done

**Primary**: macOS user running 2+ Claude Code sessions in parallel across different projects (snor-oh's existing audience per the buddy-roadmap North Star).

**JTBD**: *When I come back to my Mac after being away, I want to know at a glance what each of my Claude sessions did while I was gone so I can decide what to look at first, without cycling through every terminal.*

## User Stories

1. I step away for a 20-minute meeting. Two sessions finish tasks, one hits an error. When I return, my pet's speech bubble says "3 projects active — tap to see". I tap, the panel opens, I hover each row, and I know exactly where to click in 10 seconds.
2. I come back from lunch and no sessions did anything interesting. The pet is quiet — no bubble. I'm not interrupted by a "you missed nothing" message.
3. An hour later I want to re-check what happened at lunch. I hover the project row and the tooltip still shows the digest (frozen until the next away window).
4. I want the digest feature off because I find it chatty. I uncheck "Away digest" in Settings → General. Tooltips disappear immediately, no bubble fires on next return.
5. I prefer a 20-minute threshold because 10 min fires after every bathroom break. I drag the slider in Settings and the next away detection honors it.

## UX Flow

```
[away ≥ threshold]
       │
       ▼
accumulate per-project events silently
(0 CPU cost — piggybacks on existing notifications)
       │
       ▼
[user returns — any keypress/mouse within last 2s]
       │
       ├──► any digest non-empty? ─── yes ──► welcome-back bubble:
       │                                      "Project-A: 2 tasks done, 3 files changed"
       │                                      (single-project) OR
       │                                      "3 projects active — tap to see" (multi)
       │                              no ──► silent; tooltips update invisibly
       │
       ▼
tooltips on project rows stay frozen with this digest
until the NEXT away-window opens (or user right-clicks → Clear digest)
```

**Tooltip layout (plain text, `\n`-joined for `.help()`):**

```
While you were away (12:05–13:30):
▲ 2 tasks completed · 8m total
▲ 3 files changed
Last active: 13:12
```

**Empty-state tooltip** (project had no events during the away window):

```
While you were away (12:05–13:30):
no activity on this project
```

**Feature-disabled tooltip:** no `.help()` attached — native system behavior (no tooltip appears at all).

## Acceptance Criteria

- [ ] `UserIdleTracker.poll()` called exactly once per existing 2s `Watchdog.tick()` — **no new timer, no new queue**
- [ ] When `awayDigestEnabled == false`, `UserIdleTracker` short-circuits before any syscall, `AwayDigestCollector` ignores all inbound notifications, and `.help(...)` on project rows returns `""` so no tooltip appears
- [ ] `.userAwayStarted` posts exactly once per crossing of the threshold (no flapping at boundary — hysteresis applied)
- [ ] `.userReturned` fires on `secondsSinceLast < 2` and reports `awayDuration` in its `userInfo`
- [ ] Events posted during `.present` are ignored by `AwayDigestCollector` (never appear in any digest)
- [ ] On `.userReturned`, digests are snapshotted and remain readable until the next `.userAwayStarted` or an explicit "Clear digest" menu action
- [ ] Welcome-back bubble does **not** fire when all project digests are empty (zero-activity return is silent)
- [ ] Single-project digest produces a one-line bubble; 2+ project digests produce a generic "N projects active — tap to see" bubble that opens the panel on tap
- [ ] Settings → General exposes: "Away digest" checkbox + threshold slider (3–60 min, default 10). Changes take effect immediately without restart
- [ ] Project row gains a `"Clear digest"` item in its existing `.contextMenu`, visible only when a non-empty digest exists for that project
- [ ] System sleep / lid close does not produce a spurious multi-hour digest — `awayDuration` is clamped at wall-clock since tracker was last active
- [ ] No regression on existing `.taskCompleted` consumers — the added `pid` key is additive in `userInfo`
- [ ] Tests pass as specified in [§Testing](#testing) with branch coverage of both state machines

## Data Model

All runtime-only; nothing persisted to disk.

```swift
// Sources/Core/ProjectDigest.swift — new

enum ProjectEventKind {
    case task           // a busy→idle transition (task completion)
    case sessionEnded   // a session disappeared (any→disconnected)
    case filesChanged   // git status delta (cumulative via filesDelta)
}

struct ProjectEvent {
    let kind: ProjectEventKind
    let timestamp: Date
    let durationSecs: UInt64   // 0 for non-task events
    let filesDelta: Int        // signed, used only for .filesChanged
}

struct ProjectDigest {
    let projectPath: String
    var awayWindowStart: Date
    var events: [ProjectEvent]     // cap at 20 per project; oldest wins eviction
    var isEmpty: Bool { events.isEmpty }
}

struct DigestSnapshot {
    let projectPath: String
    let awayWindowStart: Date
    let awayWindowEnd: Date
    let taskCount: Int
    let totalTaskSecs: UInt64
    let filesDelta: Int         // net
    let sessionsEnded: Int
    let lastActivity: Date?
}
```

```swift
// Sources/Core/UserIdleTracker.swift — new

protocol IdleSecondsProvider {
    func secondsSinceLastEvent() -> TimeInterval
}

struct SystemIdleProvider: IdleSecondsProvider {
    func secondsSinceLastEvent() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .init(rawValue: ~0)!)
    }
}

@Observable
final class UserIdleTracker {
    enum State { case present, away(since: Date) }
    private(set) var state: State = .present
    var thresholdSecs: TimeInterval = 600      // 10 min default
    var provider: IdleSecondsProvider = SystemIdleProvider()
    var enabled: Bool = true

    func poll() {
        guard enabled else { return }
        let seconds = provider.secondsSinceLastEvent()
        // state machine: present → away at ≥threshold; away → present at <2s hysteresis
    }
}
```

```swift
// Sources/Core/AwayDigestCollector.swift — new

@Observable
final class AwayDigestCollector {
    var enabled: Bool = true
    private var digests: [String: ProjectDigest] = [:]
    private var isAccumulating: Bool = false

    // Subscribes to: .userAwayStarted, .userReturned, .taskCompleted,
    //                .statusChanged, .projectFileDelta (new)
    // Exposes:      digest(for:), welcomeBackSummary(), clearDigest(for:)
}
```

```swift
// Sources/Util/Defaults.swift — extend

enum DefaultsKey {
    // existing cases...
    case awayDigestEnabled          // Bool, default true
    case awayDigestThresholdMins    // Int,  default 10, range 3…60
}
```

```swift
// Sources/Core/SessionManager.swift — tiny additive change

// In handleStatus(...) when posting .taskCompleted, add pid to userInfo:
NotificationCenter.default.post(
    name: .taskCompleted,
    object: nil,
    userInfo: ["duration_secs": duration, "pid": pid]   // pid is NEW
)
```

```swift
// Sources/Core/SessionManager.swift + Sources/Network/GitStatus.swift

// New notification name
extension Notification.Name {
    static let userAwayStarted   = Notification.Name("userAwayStarted")
    static let userReturned      = Notification.Name("userReturned")
    static let projectFileDelta  = Notification.Name("projectFileDelta")
}

// GitStatus.swift: post .projectFileDelta when modifiedFiles count changes
// (currently only updates the ProjectStatus field via updateModifiedFiles).
```

## Implementation Notes

| Concern | Fit |
|---|---|
| Idle API choice | `CGEventSourceSecondsSinceLastEventType(.combinedSessionState, .null)` — system-wide, merges HID + synthetic events. `.hidSystemState` alone misses Raycast/tooling synthesizers. |
| Polling cadence | Reuse existing `Watchdog.tick()` (2s). No new `Timer`. One extra syscall per tick = microseconds. |
| Threshold default | **10 min**, not 5. In snor-oh's usage context "5 min of no input" frequently means "reading long task output" — too chatty. 10 min reliably means "stepped away". User-configurable 3–60. |
| Hysteresis | Return fires at `secondsSinceLast < 2` (not `== 0`) to avoid phantom returns when the 2s tick lands between a true away and a single stray event. |
| Clock skew | State compared against monotonic `secondsSinceLast`, never `Date()` arithmetic. NTP jumps and DST are safe. |
| System sleep | On wake the gap reports fully. Collector clamps `awayDuration` at wall-clock-since-tracker-start to avoid "away for 8 hours" after overnight sleep. |
| Tooltip rendering | SwiftUI native `.help(String)` on project row `HStack`. Plain-text, `\n`-joined. System handles hover delay and positioning. No custom popover in v1. |
| Welcome-back bubble | Reuses existing `BubbleManager.post(message:, dismissAfter:)`. Copy rules: single-project bubble ≤ 60 chars; multi-project generic "N projects — tap to see". Tap handler opens panel (same path as existing task-done bubble tap). |
| Memory cap | `ProjectDigest.events` capped at 20; oldest evicted. 20 × 32 bytes × N projects — negligible. |
| DI pattern | Matches `SessionLivenessChecking` / `SessionProcessScanning` already in use — `IdleSecondsProvider` protocol with a `SystemIdleProvider` default and a `MockIdleProvider` in tests. |
| Concurrency | All `@MainActor`. Notification observers bounced through `MainActor.run` — same pattern as `MascotView` bucketChanged observer. |
| Lifecycle | `UserIdleTracker` + `AwayDigestCollector` instantiated in `AppDelegate.applicationDidFinishLaunching` right after `SessionManager`. Tracker passed into `Watchdog` at init (optional; `nil` when feature off). |

## Out of Scope

- **Rich hover popover with chips, icons, timeline bullets.** Deferred to a v2 (Approach B). The v1 tooltip data model already stores timestamped events so v2 is a rendering-only upgrade with no data migration.
- **Persisting digests across relaunch.** Away state is ephemeral. A crash or restart starts fresh.
- **Per-session (as opposed to per-project) digests.** Users think in projects, not PIDs. Multiple sessions in the same CWD collapse into the same digest — matches existing `ProjectStatus` aggregation.
- **Cross-device peer digest** ("while you were away, your laptop finished a build"). Out of charter; Bonjour trust surface would need new design.
- **Summarization via LLM.** No Claude calls, no network, no cost. Per-project rollups are templated from structured event counts.
- **Audio / haptic notification on return.** Bubble is enough.
- **Integration with `CLAUDE_CODE_ENABLE_AWAY_SUMMARY`.** Internal upstream flag with no emission surface — tracked as a future follow-up if/when Anthropic ships a `SessionRecap` hook or MCP notification, at which point a `pet_recap` MCP tool would be the natural delivery path.

## Open Questions

- [ ] Should the welcome-back bubble be suppressed if the user returns and immediately makes the panel active (i.e., they've already "seen" the state)? Lean: yes, with a 2s grace window.
- [ ] Should `.projectFileDelta` consider only tracked files or include untracked? (`GitStatus` currently polls `git status --porcelain`, so both count.) Lean: leave both — user doesn't care about the distinction at-a-glance.
- [ ] Should the tooltip include peer-visitor events during the away window (e.g., "peer dog visited 2×")? Lean: no for v1 — keep the digest about *your* work, not social state.
- [ ] Is "Clear digest" better as a per-project context-menu item or a single "Clear all" in the panel summary bar? Lean: both — per-project for precision, all via the summary-bar chevron.
- [ ] Accessibility: `.help()` is not read by VoiceOver by default. Should we mirror tooltip text into `.accessibilityHint(...)` on the row? Lean: yes, trivial.

## Rollout Plan

Ship as a single dot release (v1.1 per roadmap cadence).

| # | Task | Files | Depends on |
|---|------|-------|-----------|
| 1 | Add `DefaultsKey.awayDigestEnabled` + `.awayDigestThresholdMins` | `Util/Defaults.swift` | – |
| 2 | Define `Notification.Name` additions + `ProjectEvent`/`ProjectDigest`/`DigestSnapshot` value types | `Core/Types.swift`, `Core/ProjectDigest.swift` | 1 |
| 3 | Implement `UserIdleTracker` with `IdleSecondsProvider` DI + state machine + hysteresis + enabled gate | `Core/UserIdleTracker.swift` | 2 |
| 4 | Unit tests for tracker state machine | `Tests/UserIdleTrackerTests.swift` | 3 |
| 5 | Implement `AwayDigestCollector` (notification subscriptions, accumulation, snapshot, clear, enabled gate) | `Core/AwayDigestCollector.swift` | 2 |
| 6 | Unit tests for collector | `Tests/AwayDigestCollectorTests.swift` | 5 |
| 7 | Extend `SessionManager.handleStatus` to include `pid` in `.taskCompleted` userInfo | `Core/SessionManager.swift` | – |
| 8 | `GitStatus` posts `.projectFileDelta` on count change | `Network/GitStatus.swift` | 2 |
| 9 | `Watchdog.tick()` calls `userIdleTracker?.poll()` | `Core/Watchdog.swift` | 3 |
| 10 | Instantiate tracker + collector in `AppDelegate`; wire config toggle to enabled flag | `App/AppDelegate.swift` | 3, 5 |
| 11 | `ProjectDigestTooltip.tooltipText(...)` pure function + golden-string tests | `Views/ProjectDigestTooltip.swift`, `Tests/ProjectDigestTooltipTests.swift` | 5 |
| 12 | Attach `.help(...)` to project row `HStack` + "Clear digest" context-menu item | `Views/SnorOhPanelView.swift` | 11 |
| 13 | Welcome-back bubble handler (listens for `.userReturned`, composes text, posts via `BubbleManager`) | `Views/SpeechBubble.swift` (BubbleManager section) | 5 |
| 14 | Settings → General UI: checkbox + slider, live-effective | `Views/SettingsView.swift` | 10 |
| 15 | Manual verification: real away walk-away, multi-project digest, zero-activity return, feature-off round-trip | – | all |
| 16 | Release-build verify via `bash Scripts/build-release.sh` per CLAUDE.md workflow | – | 15 |

## Success Metrics

| Metric | Target | Method |
|---|---|---|
| % of users who return to a non-empty digest and click/hover at least one project within 30s | ≥40% | Local counter: bubble-post → first project-row interaction timestamp delta |
| % of users who disable the feature within first 7 days | <15% | Defaults key last-modified timestamp vs first-launch |
| Median away-window length that produces a non-empty digest | 15–45 min | Observed `awayDuration` distribution |
| Welcome-back bubble tap-through rate | ≥25% | Bubble tap event vs bubble post event |
| No regression in 2s `Watchdog.tick()` median duration | ≤ +5% vs baseline | Local timing in debug builds |
