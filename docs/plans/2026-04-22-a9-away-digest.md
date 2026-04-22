# A9 Away Digest — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Ship the A9 Away Digest feature — real user-idle detection that accumulates per-project events during an away window and surfaces them via a tooltip on each project row plus a one-shot welcome-back speech bubble on return — exactly as specified in `docs/prd/A9-away-digest.md` (Approach C v1).

**Architecture:** Three new core types (`UserIdleTracker`, `AwayDigestCollector`, `ProjectDigest` value types) subscribe to notifications that `SessionManager` and `GitStatus` already post (plus two tiny additive changes: `pid` in `.taskCompleted` userInfo, and a new `.projectFileDelta` emission). Detection piggybacks on the existing 2-second `Watchdog.tick()` — zero new timers. Surfaces are SwiftUI native `.help()` on project rows + existing `BubbleManager` for the welcome-back bubble. Feature is gated by a `awayDigestEnabled` Defaults key with a live-effective Settings toggle.

**Tech Stack:** Swift 5.9, SwiftUI, `@Observable` (macOS 14 Sonoma), SwiftNIO (existing), XCTest. System APIs: `CGEventSourceSecondsSinceLastEventType` from ApplicationServices. No new dependencies.

**Prereq / housekeeping:**
- Working tree currently has unrelated modifications in `Sources/Animation/SpriteConfig.swift` and `Sources/Core/Types.swift`. **Leave them alone** — each task's commit should include only files it created/touched. If you're uncomfortable with that, create a worktree first: `git worktree add ../snor-oh-a9 a9-away-digest` and proceed there.
- Target module name is `SnorOhSwift` (per `Package.swift`). Tests use `@testable import SnorOhSwift`.
- Build: `swift build`. Tests: `swift test`. Filter a single test: `swift test --filter SnorOhSwiftTests.TestClass/testMethod`. Release package: `bash Scripts/build-release.sh`.
- Minimum macOS: 14.0 (enforced by `@Observable`).
- Default conventions confirmed in `Tests/SessionManagerTests.swift` and `Sources/Util/Defaults.swift`.

---

## Task 1: Add Defaults keys

**Files:**
- Modify: `Sources/Util/Defaults.swift`

**Step 1: Read `Sources/Util/Defaults.swift`** to locate the `DefaultsKey` enum and see the existing pattern (cases return UserDefaults key strings, plus any defaultValue helpers).

**Step 2: Add two cases to the enum**

Insert next to existing keys (keep alphabetical order if the file is alphabetized; otherwise group with similar feature flags):

```swift
case awayDigestEnabled       // Bool,  default true
case awayDigestThresholdMins // Int,   default 10, valid range 3…60
```

Update `rawValue` / string mapping to match the existing pattern exactly (camelCase key string). If the file has a `defaultValue` switch, add:

```swift
case .awayDigestEnabled:       return true
case .awayDigestThresholdMins: return 10
```

**Step 3: Build** — `swift build`. Expected: build succeeds (this is additive only).

**Step 4: Commit**

```bash
git add Sources/Util/Defaults.swift
git commit -m "a9: add awayDigestEnabled + threshold Defaults keys"
```

---

## Task 2: Add Notification.Name extensions

**Files:**
- Modify: `Sources/Core/SessionManager.swift` (the existing `extension Notification.Name` block near the top)

**Step 1: Add three new notification names** to the existing `extension Notification.Name` block:

```swift
/// A9 — posted by UserIdleTracker when user-idle exceeds the configured
/// threshold (default 10 min). `userInfo` is empty; the collector records
/// its own `awayWindowStart`.
static let userAwayStarted = Notification.Name("userAwayStarted")

/// A9 — posted by UserIdleTracker when any real user input returns after
/// a prior `.userAwayStarted`. `userInfo`:
///   - `"away_duration_secs": UInt64`
static let userReturned = Notification.Name("userReturned")

/// A9 — posted by GitStatus when a project's modifiedFiles count changes.
/// `userInfo`:
///   - `"path": String`
///   - `"delta": Int`  (signed; can be negative when files revert)
static let projectFileDelta = Notification.Name("projectFileDelta")
```

**Step 2: Build** — `swift build`. Expected: succeeds.

**Step 3: Commit**

```bash
git add Sources/Core/SessionManager.swift
git commit -m "a9: declare userAwayStarted/userReturned/projectFileDelta notifications"
```

---

## Task 3: Create ProjectDigest value types

**Files:**
- Create: `Sources/Core/ProjectDigest.swift`

**Step 1: Write the new file** with all value types used by the collector and renderer:

```swift
import Foundation

// MARK: - Event kinds tracked inside an away window

enum ProjectEventKind {
    case task           // busy -> idle transition completed a task
    case sessionEnded   // a session disappeared (any -> disconnected)
    case filesChanged   // git status delta (cumulative via filesDelta)
}

// MARK: - Raw event (stored per project during accumulation)

struct ProjectEvent {
    let kind: ProjectEventKind
    let timestamp: Date
    let durationSecs: UInt64  // 0 for non-task events
    let filesDelta: Int       // signed; meaningful only for .filesChanged
}

// MARK: - Per-project digest maintained by the collector

struct ProjectDigest {
    let projectPath: String
    var awayWindowStart: Date
    var awayWindowEnd: Date?  // nil while accumulating; set on snapshot
    var events: [ProjectEvent]

    static let eventCap = 20  // oldest evicted when exceeded

    var isEmpty: Bool { events.isEmpty }

    mutating func append(_ event: ProjectEvent) {
        events.append(event)
        if events.count > Self.eventCap {
            events.removeFirst(events.count - Self.eventCap)
        }
    }
}

// MARK: - Immutable snapshot consumed by tooltip + bubble

struct DigestSnapshot {
    let projectPath: String
    let awayWindowStart: Date
    let awayWindowEnd: Date
    let taskCount: Int
    let totalTaskSecs: UInt64
    let filesDelta: Int          // net across the window
    let sessionsEnded: Int
    let lastActivity: Date?

    init(from digest: ProjectDigest, windowEnd: Date) {
        self.projectPath = digest.projectPath
        self.awayWindowStart = digest.awayWindowStart
        self.awayWindowEnd = windowEnd

        var taskCount = 0
        var totalTaskSecs: UInt64 = 0
        var filesDelta = 0
        var sessionsEnded = 0
        var lastActivity: Date? = nil

        for e in digest.events {
            switch e.kind {
            case .task:
                taskCount += 1
                totalTaskSecs += e.durationSecs
            case .sessionEnded:
                sessionsEnded += 1
            case .filesChanged:
                filesDelta += e.filesDelta
            }
            if lastActivity == nil || e.timestamp > lastActivity! {
                lastActivity = e.timestamp
            }
        }

        self.taskCount = taskCount
        self.totalTaskSecs = totalTaskSecs
        self.filesDelta = filesDelta
        self.sessionsEnded = sessionsEnded
        self.lastActivity = lastActivity
    }

    var isEmpty: Bool {
        taskCount == 0 && filesDelta == 0 && sessionsEnded == 0
    }
}
```

**Step 2: Build** — `swift build`. Expected: succeeds.

**Step 3: Commit**

```bash
git add Sources/Core/ProjectDigest.swift
git commit -m "a9: add ProjectDigest value types + snapshot rollup"
```

---

## Task 4: Create IdleSecondsProvider + SystemIdleProvider

**Files:**
- Create: `Sources/Core/UserIdleTracker.swift`

**Step 1: Write the provider abstraction** (the tracker implementation follows in Task 6 — TDD).

```swift
import Foundation
import ApplicationServices

// MARK: - DI seam for testing

protocol IdleSecondsProvider {
    func secondsSinceLastEvent() -> TimeInterval
}

/// Reads combined-session idle seconds from Core Graphics. Merges HID +
/// synthetic events (so Raycast/tooling doesn't register as "away").
/// Single syscall, microsecond cost.
struct SystemIdleProvider: IdleSecondsProvider {
    func secondsSinceLastEvent() -> TimeInterval {
        // CGEventType is an OptionSet-ish RawRepresentable; ~0 asks "any event".
        let anyEvent = CGEventType(rawValue: ~0)!
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyEvent)
    }
}

// UserIdleTracker implementation — filled in by Task 6 (TDD).
```

**Step 2: Build** — `swift build`. Expected: succeeds.

**Step 3: Commit**

```bash
git add Sources/Core/UserIdleTracker.swift
git commit -m "a9: add IdleSecondsProvider + SystemIdleProvider"
```

---

## Task 5: Write UserIdleTracker state-machine tests (failing)

**Files:**
- Create: `Tests/UserIdleTrackerTests.swift`

**Step 1: Write the test file with a Mock provider and state transition tests**

```swift
import XCTest
@testable import SnorOhSwift

final class UserIdleTrackerTests: XCTestCase {

    // MARK: - Mock provider

    final class MockIdleProvider: IdleSecondsProvider {
        var script: [TimeInterval] = []
        var index = 0
        func secondsSinceLastEvent() -> TimeInterval {
            defer { index = min(index + 1, script.count - 1) }
            guard !script.isEmpty else { return 0 }
            return script[index]
        }
    }

    // MARK: - Helpers

    func observe(_ name: Notification.Name) -> (count: () -> Int, latest: () -> [AnyHashable: Any]?) {
        var received: [[AnyHashable: Any]?] = []
        let token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { note in
            received.append(note.userInfo)
        }
        addTeardownBlock { NotificationCenter.default.removeObserver(token) }
        return ({ received.count }, { received.last ?? nil })
    }

    // MARK: - Tests

    func testInitialStatePresent() {
        let t = UserIdleTracker()
        t.provider = MockIdleProvider()
        if case .present = t.state { } else { XCTFail("expected .present initial state") }
    }

    func testPresentToAwayFiresOnceAtThreshold() {
        let t = UserIdleTracker()
        let mock = MockIdleProvider()
        mock.script = [0, 10, 300, 600, 900]  // crosses 300 on third poll
        t.provider = mock
        t.thresholdSecs = 300

        let away = observe(.userAwayStarted)

        t.poll(); t.poll()                    // 0, 10 -> still .present
        XCTAssertEqual(away.count(), 0)

        t.poll()                               // 300 -> crosses
        XCTAssertEqual(away.count(), 1)
        guard case .away(since: _) = t.state else {
            XCTFail("expected .away after crossing threshold"); return
        }

        t.poll(); t.poll()                    // still away, no re-post
        XCTAssertEqual(away.count(), 1)
    }

    func testAwayToPresentFiresOnceWithDuration() {
        let t = UserIdleTracker()
        let mock = MockIdleProvider()
        mock.script = [600, 600, 1, 0]
        t.provider = mock
        t.thresholdSecs = 300

        let ret = observe(.userReturned)

        t.poll()  // -> away
        t.poll()  // still away
        t.poll()  // 1 < 2 hysteresis -> return
        XCTAssertEqual(ret.count(), 1)
        let away = ret.latest()?["away_duration_secs"] as? UInt64
        XCTAssertNotNil(away)
        XCTAssertGreaterThanOrEqual(away ?? 0, 1)

        t.poll()  // 0 -> no re-post
        XCTAssertEqual(ret.count(), 1)
    }

    func testFlappingNearThresholdDoesNotFire() {
        let t = UserIdleTracker()
        let mock = MockIdleProvider()
        mock.script = [299, 301, 299, 301, 299]
        t.provider = mock
        t.thresholdSecs = 300

        let away = observe(.userAwayStarted)
        let ret  = observe(.userReturned)

        // First poll: 299 < threshold -> stays present
        // Second poll: 301 >= threshold -> transitions to away ONCE
        // Subsequent dips to 299 do NOT return (299 >= hysteresis=2), stays away
        for _ in 0..<5 { t.poll() }

        XCTAssertEqual(away.count(), 1, "threshold crossed exactly once")
        XCTAssertEqual(ret.count(), 0,  "299s never drops below hysteresis=2, no return")
    }

    func testDisabledGatesPoll() {
        let t = UserIdleTracker()
        let mock = MockIdleProvider()
        mock.script = [0, 600, 600]
        t.provider = mock
        t.enabled = false

        let away = observe(.userAwayStarted)

        for _ in 0..<3 { t.poll() }
        XCTAssertEqual(away.count(), 0)
        if case .present = t.state { } else { XCTFail("disabled tracker must stay .present") }
    }

    func testDisablingMidAwayStopsFurtherTransitions() {
        let t = UserIdleTracker()
        let mock = MockIdleProvider()
        mock.script = [600, 600, 0, 0]
        t.provider = mock

        let ret = observe(.userReturned)

        t.poll()          // -> away
        t.enabled = false
        t.poll(); t.poll()
        XCTAssertEqual(ret.count(), 0, "disabled tracker must not post .userReturned")
    }
}
```

**Step 2: Run tests to verify they fail for the right reason**

```bash
swift test --filter SnorOhSwiftTests.UserIdleTrackerTests
```

Expected: **compile error** — `UserIdleTracker` type not defined yet. That's the RED in our RED-GREEN-COMMIT cycle.

**Step 3: Do not commit yet** — red tests go in the same commit as the implementation that turns them green (Task 6). Leave them staged or on disk.

---

## Task 6: Implement UserIdleTracker to make Task 5 pass

**Files:**
- Modify: `Sources/Core/UserIdleTracker.swift`

**Step 1: Append the `UserIdleTracker` class** to the file created in Task 4:

```swift
// MARK: - Tracker

@Observable
final class UserIdleTracker {

    enum State: Equatable {
        case present
        case away(since: Date)
    }

    /// Threshold for present -> away transition, seconds. Default 10 min.
    var thresholdSecs: TimeInterval = 600

    /// Hysteresis guard on the away -> present edge: a single tick reading
    /// below this value triggers return. 2s absorbs any jitter from the 2s
    /// watchdog tick landing between a real away and a stray event.
    var returnHysteresisSecs: TimeInterval = 2

    /// Live-toggle gate. When false, `poll()` short-circuits.
    var enabled: Bool = true

    /// Injectable for tests. Production uses `SystemIdleProvider`.
    var provider: IdleSecondsProvider = SystemIdleProvider()

    private(set) var state: State = .present

    func poll() {
        guard enabled else { return }
        let secondsIdle = provider.secondsSinceLastEvent()
        let now = Date()

        switch state {
        case .present:
            if secondsIdle >= thresholdSecs {
                // Start of away window: approximate start as (now - secondsIdle).
                let start = now.addingTimeInterval(-secondsIdle)
                state = .away(since: start)
                NotificationCenter.default.post(name: .userAwayStarted, object: nil)
            }
        case .away(let since):
            if secondsIdle < returnHysteresisSecs {
                let duration = UInt64(max(0, now.timeIntervalSince(since)))
                state = .present
                NotificationCenter.default.post(
                    name: .userReturned,
                    object: nil,
                    userInfo: ["away_duration_secs": duration]
                )
            }
        }
    }
}
```

**Step 2: Run the Task 5 tests**

```bash
swift test --filter SnorOhSwiftTests.UserIdleTrackerTests
```

Expected: **all six tests pass**.

**Step 3: Run the full suite** to confirm no regressions.

```bash
swift test
```

Expected: all tests pass.

**Step 4: Commit** — group red tests + green implementation into one commit (atomic unit).

```bash
git add Sources/Core/UserIdleTracker.swift Tests/UserIdleTrackerTests.swift
git commit -m "a9: UserIdleTracker state machine + hysteresis (TDD)"
```

---

## Task 7: Write AwayDigestCollector tests (failing)

**Files:**
- Create: `Tests/AwayDigestCollectorTests.swift`

**Step 1: Write the test file**

```swift
import XCTest
@testable import SnorOhSwift

final class AwayDigestCollectorTests: XCTestCase {

    var collector: AwayDigestCollector!
    var sm: SessionManager!

    override func setUp() {
        super.setUp()
        sm = SessionManager()
        collector = AwayDigestCollector(sessionManager: sm)
    }

    override func tearDown() {
        collector = nil
        sm = nil
        super.tearDown()
    }

    // MARK: - accumulation gating

    func testEventsDuringPresentAreIgnored() {
        // No .userAwayStarted posted -> collector is .present
        NotificationCenter.default.post(
            name: .taskCompleted, object: nil,
            userInfo: ["duration_secs": UInt64(120), "pid": UInt32(1)]
        )
        XCTAssertNil(collector.digest(for: "/tmp/p"))
    }

    func testEventsDuringAwayAccumulate() {
        // Register a session so pid -> path mapping works
        sm.handleStatus(pid: 1, state: "busy", type: "task", cwd: "/tmp/project-a")

        NotificationCenter.default.post(name: .userAwayStarted, object: nil)

        NotificationCenter.default.post(
            name: .taskCompleted, object: nil,
            userInfo: ["duration_secs": UInt64(60), "pid": UInt32(1)]
        )
        NotificationCenter.default.post(
            name: .taskCompleted, object: nil,
            userInfo: ["duration_secs": UInt64(30), "pid": UInt32(1)]
        )

        let d = collector.digest(for: "/tmp/project-a")
        XCTAssertNotNil(d)
        XCTAssertEqual(d?.events.count, 2)
    }

    func testFileDeltaAccumulates() {
        NotificationCenter.default.post(name: .userAwayStarted, object: nil)

        NotificationCenter.default.post(
            name: .projectFileDelta, object: nil,
            userInfo: ["path": "/tmp/p", "delta": 3]
        )
        NotificationCenter.default.post(
            name: .projectFileDelta, object: nil,
            userInfo: ["path": "/tmp/p", "delta": -1]
        )

        let d = collector.digest(for: "/tmp/p")
        XCTAssertNotNil(d)
        XCTAssertEqual(d?.events.count, 2)
    }

    // MARK: - snapshot on return

    func testReturnSnapshotsDigests() {
        sm.handleStatus(pid: 1, state: "busy", type: "task", cwd: "/tmp/a")

        NotificationCenter.default.post(name: .userAwayStarted, object: nil)
        NotificationCenter.default.post(
            name: .taskCompleted, object: nil,
            userInfo: ["duration_secs": UInt64(90), "pid": UInt32(1)]
        )
        NotificationCenter.default.post(
            name: .userReturned, object: nil,
            userInfo: ["away_duration_secs": UInt64(1200)]
        )

        let snap = collector.snapshot(for: "/tmp/a")
        XCTAssertNotNil(snap)
        XCTAssertEqual(snap?.taskCount, 1)
        XCTAssertEqual(snap?.totalTaskSecs, 90)
    }

    func testWelcomeBackSummaryNilWhenEmpty() {
        NotificationCenter.default.post(name: .userAwayStarted, object: nil)
        NotificationCenter.default.post(
            name: .userReturned, object: nil,
            userInfo: ["away_duration_secs": UInt64(1200)]
        )
        XCTAssertNil(collector.welcomeBackSummary())
    }

    func testWelcomeBackSummarySingleProject() {
        sm.handleStatus(pid: 1, state: "busy", type: "task", cwd: "/tmp/api")
        NotificationCenter.default.post(name: .userAwayStarted, object: nil)
        NotificationCenter.default.post(
            name: .taskCompleted, object: nil,
            userInfo: ["duration_secs": UInt64(60), "pid": UInt32(1)]
        )
        NotificationCenter.default.post(
            name: .projectFileDelta, object: nil,
            userInfo: ["path": "/tmp/api", "delta": 2]
        )
        NotificationCenter.default.post(
            name: .userReturned, object: nil,
            userInfo: ["away_duration_secs": UInt64(1200)]
        )

        let msg = collector.welcomeBackSummary()
        XCTAssertNotNil(msg)
        XCTAssertTrue(msg!.contains("api"))
    }

    func testWelcomeBackSummaryMultiProject() {
        sm.handleStatus(pid: 1, state: "busy", type: "task", cwd: "/tmp/a")
        sm.handleStatus(pid: 2, state: "busy", type: "task", cwd: "/tmp/b")

        NotificationCenter.default.post(name: .userAwayStarted, object: nil)
        NotificationCenter.default.post(
            name: .taskCompleted, object: nil,
            userInfo: ["duration_secs": UInt64(60), "pid": UInt32(1)]
        )
        NotificationCenter.default.post(
            name: .taskCompleted, object: nil,
            userInfo: ["duration_secs": UInt64(60), "pid": UInt32(2)]
        )
        NotificationCenter.default.post(
            name: .userReturned, object: nil,
            userInfo: ["away_duration_secs": UInt64(1200)]
        )

        let msg = collector.welcomeBackSummary()
        XCTAssertNotNil(msg)
        XCTAssertTrue(msg!.contains("2 projects") || msg!.contains("projects"),
                      "multi-project message should mention project count")
    }

    // MARK: - manual clear

    func testClearDigest() {
        sm.handleStatus(pid: 1, state: "busy", type: "task", cwd: "/tmp/a")
        NotificationCenter.default.post(name: .userAwayStarted, object: nil)
        NotificationCenter.default.post(
            name: .taskCompleted, object: nil,
            userInfo: ["duration_secs": UInt64(60), "pid": UInt32(1)]
        )
        NotificationCenter.default.post(
            name: .userReturned, object: nil,
            userInfo: ["away_duration_secs": UInt64(1200)]
        )
        XCTAssertNotNil(collector.snapshot(for: "/tmp/a"))

        collector.clearDigest(for: "/tmp/a")
        XCTAssertNil(collector.snapshot(for: "/tmp/a"))
    }

    // MARK: - gate

    func testDisabledIgnoresEverything() {
        collector.enabled = false
        sm.handleStatus(pid: 1, state: "busy", type: "task", cwd: "/tmp/a")
        NotificationCenter.default.post(name: .userAwayStarted, object: nil)
        NotificationCenter.default.post(
            name: .taskCompleted, object: nil,
            userInfo: ["duration_secs": UInt64(60), "pid": UInt32(1)]
        )
        XCTAssertNil(collector.digest(for: "/tmp/a"))
    }

    func testToggleOffClearsAccumulation() {
        sm.handleStatus(pid: 1, state: "busy", type: "task", cwd: "/tmp/a")
        NotificationCenter.default.post(name: .userAwayStarted, object: nil)
        NotificationCenter.default.post(
            name: .taskCompleted, object: nil,
            userInfo: ["duration_secs": UInt64(60), "pid": UInt32(1)]
        )
        XCTAssertNotNil(collector.digest(for: "/tmp/a"))

        collector.enabled = false
        XCTAssertNil(collector.digest(for: "/tmp/a"),
                     "disabling must discard the in-progress window")
    }
}
```

**Step 2: Run them**

```bash
swift test --filter SnorOhSwiftTests.AwayDigestCollectorTests
```

Expected: **compile error** — `AwayDigestCollector` not defined. RED phase.

---

## Task 8: Implement AwayDigestCollector to make Task 7 pass

**Files:**
- Create: `Sources/Core/AwayDigestCollector.swift`

**Step 1: Write the implementation**

```swift
import Foundation

@Observable
final class AwayDigestCollector {

    // MARK: - Config

    /// Live-toggle gate. Turning off discards any in-progress accumulation.
    var enabled: Bool = true {
        didSet {
            if !enabled { digests.removeAll(); isAccumulating = false }
        }
    }

    // MARK: - State

    private weak var sessionManager: SessionManager?
    private var digests: [String: ProjectDigest] = [:]
    private var isAccumulating: Bool = false
    private var windowEnd: Date? = nil
    private var observers: [NSObjectProtocol] = []

    // MARK: - Lifecycle

    init(sessionManager: SessionManager) {
        self.sessionManager = sessionManager
        subscribe()
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: - Public API

    /// Live digest (mutable accumulator) — primarily for tests.
    func digest(for path: String) -> ProjectDigest? {
        digests[path]
    }

    /// Immutable snapshot rollup, consumed by tooltip + bubble.
    func snapshot(for path: String) -> DigestSnapshot? {
        guard let d = digests[path], let end = windowEnd ?? d.awayWindowEnd else { return nil }
        let snap = DigestSnapshot(from: d, windowEnd: end)
        return snap.isEmpty ? nil : snap
    }

    /// Returns a single short string suitable for a BubbleManager post, or nil
    /// when there is nothing to report (zero-activity return).
    func welcomeBackSummary() -> String? {
        let nonEmpty = digests.values.compactMap { d -> DigestSnapshot? in
            guard let end = windowEnd ?? d.awayWindowEnd else { return nil }
            let s = DigestSnapshot(from: d, windowEnd: end)
            return s.isEmpty ? nil : s
        }
        guard !nonEmpty.isEmpty else { return nil }

        if nonEmpty.count == 1 {
            let s = nonEmpty[0]
            let name = (s.projectPath as NSString).lastPathComponent
            var parts: [String] = []
            if s.taskCount > 0 {
                let mins = max(1, Int(s.totalTaskSecs / 60))
                parts.append("\(s.taskCount) task\(s.taskCount == 1 ? "" : "s") · \(mins)m")
            }
            if s.filesDelta != 0 {
                parts.append("\(abs(s.filesDelta)) file\(abs(s.filesDelta) == 1 ? "" : "s") changed")
            }
            return "\(name): " + parts.joined(separator: ", ")
        }

        return "\(nonEmpty.count) projects active while you were away — tap to see"
    }

    func clearDigest(for path: String) {
        digests.removeValue(forKey: path)
    }

    func clearAll() {
        digests.removeAll()
    }

    // MARK: - Notification wiring

    private func subscribe() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .userAwayStarted, object: nil, queue: nil) { [weak self] _ in
            self?.handleAwayStarted()
        })
        observers.append(nc.addObserver(forName: .userReturned, object: nil, queue: nil) { [weak self] _ in
            self?.handleReturned()
        })
        observers.append(nc.addObserver(forName: .taskCompleted, object: nil, queue: nil) { [weak self] note in
            self?.handleTaskCompleted(note)
        })
        observers.append(nc.addObserver(forName: .projectFileDelta, object: nil, queue: nil) { [weak self] note in
            self?.handleFileDelta(note)
        })
        observers.append(nc.addObserver(forName: .statusChanged, object: nil, queue: nil) { [weak self] note in
            self?.handleStatusChanged(note)
        })
    }

    // MARK: - Handlers

    private func handleAwayStarted() {
        guard enabled else { return }
        digests.removeAll()
        isAccumulating = true
        windowEnd = nil
    }

    private func handleReturned() {
        guard enabled else { return }
        isAccumulating = false
        windowEnd = Date()
        for key in digests.keys {
            digests[key]?.awayWindowEnd = windowEnd
        }
    }

    private func handleTaskCompleted(_ note: Notification) {
        guard enabled, isAccumulating else { return }
        guard let pid = note.userInfo?["pid"] as? UInt32 else { return }
        guard let path = sessionManager?.sessions[pid]?.cwd else { return }
        let duration = note.userInfo?["duration_secs"] as? UInt64 ?? 0
        record(path: path, event: ProjectEvent(
            kind: .task, timestamp: Date(),
            durationSecs: duration, filesDelta: 0
        ))
    }

    private func handleFileDelta(_ note: Notification) {
        guard enabled, isAccumulating else { return }
        guard let path = note.userInfo?["path"] as? String else { return }
        let delta = note.userInfo?["delta"] as? Int ?? 0
        guard delta != 0 else { return }
        record(path: path, event: ProjectEvent(
            kind: .filesChanged, timestamp: Date(),
            durationSecs: 0, filesDelta: delta
        ))
    }

    private func handleStatusChanged(_ note: Notification) {
        guard enabled, isAccumulating else { return }
        // Only record session-ended transitions (any -> disconnected).
        let newRaw = note.userInfo?["status"] as? String
        let prevRaw = note.userInfo?["previous"] as? String
        guard newRaw == Status.disconnected.rawValue,
              prevRaw != Status.disconnected.rawValue,
              let sm = sessionManager else { return }
        // Attribute to every project currently tracked — coarse but acceptable
        // for v1 (sessionEnded is rare during away; no pid available here).
        for path in Set(sm.sessions.values.compactMap(\.cwd)) {
            record(path: path, event: ProjectEvent(
                kind: .sessionEnded, timestamp: Date(),
                durationSecs: 0, filesDelta: 0
            ))
        }
    }

    // MARK: - Internals

    private func record(path: String, event: ProjectEvent) {
        if digests[path] == nil {
            digests[path] = ProjectDigest(
                projectPath: path,
                awayWindowStart: Date(),
                awayWindowEnd: nil,
                events: []
            )
        }
        digests[path]?.append(event)
    }
}
```

**Step 2: Run the Task 7 tests**

```bash
swift test --filter SnorOhSwiftTests.AwayDigestCollectorTests
```

Expected: **all tests pass**. If one fails, read the specific failure and fix — do not mass-edit.

**Step 3: Run full suite**

```bash
swift test
```

Expected: pass.

**Step 4: Commit**

```bash
git add Sources/Core/AwayDigestCollector.swift Tests/AwayDigestCollectorTests.swift
git commit -m "a9: AwayDigestCollector with per-project accumulation + snapshot (TDD)"
```

---

## Task 9: Add `pid` to `.taskCompleted` userInfo

**Files:**
- Modify: `Sources/Core/SessionManager.swift:115-119`
- Modify: `Tests/SessionManagerTests.swift` — add one assertion that doesn't break existing tests

**Step 1: Extend the notification post**

In `handleStatus(...)`, change the `.taskCompleted` post from:

```swift
NotificationCenter.default.post(
    name: .taskCompleted,
    object: nil,
    userInfo: ["duration_secs": duration]
)
```

to:

```swift
NotificationCenter.default.post(
    name: .taskCompleted,
    object: nil,
    userInfo: ["duration_secs": duration, "pid": pid]
)
```

**Step 2: Add a regression test** to `Tests/SessionManagerTests.swift`:

```swift
func testTaskCompletedIncludesPid() {
    let sm = SessionManager()
    var receivedPid: UInt32? = nil
    let token = NotificationCenter.default.addObserver(forName: .taskCompleted, object: nil, queue: nil) { note in
        receivedPid = note.userInfo?["pid"] as? UInt32
    }
    defer { NotificationCenter.default.removeObserver(token) }

    sm.handleStatus(pid: 42, state: "busy", type: "task", cwd: "/tmp/x")
    sm.handleStatus(pid: 42, state: "idle", type: nil, cwd: nil)

    XCTAssertEqual(receivedPid, 42)
}
```

**Step 3: Run tests**

```bash
swift test --filter SnorOhSwiftTests.SessionManagerTests
```

Expected: all pass including the new one.

**Step 4: Commit**

```bash
git add Sources/Core/SessionManager.swift Tests/SessionManagerTests.swift
git commit -m "a9: include pid in .taskCompleted userInfo (additive)"
```

---

## Task 10: GitStatus emits `.projectFileDelta`

**Files:**
- Modify: `Sources/Network/GitStatus.swift`

**Step 1: Read `Sources/Network/GitStatus.swift`** to find the point where a polled count is written back into `SessionManager.updateModifiedFiles`. Locate the previous-count cache (a `[path: Int]` is likely already kept; if not, add one).

**Step 2: Add delta emission** right before (or after — doesn't matter) the existing count update. The pattern:

```swift
// Inside the poll result handler, path `p`, new count `newCount`:
let prev = lastCounts[p] ?? newCount   // seed to newCount on first observation -> delta 0
if newCount != prev {
    NotificationCenter.default.post(
        name: .projectFileDelta,
        object: nil,
        userInfo: ["path": p, "delta": newCount - prev]
    )
}
lastCounts[p] = newCount
```

If `lastCounts` does not exist, add it as a private property on the GitStatus type:

```swift
private var lastCounts: [String: Int] = [:]
```

**Step 3: Build**

```bash
swift build
```

Expected: succeeds.

**Step 4: Commit**

```bash
git add Sources/Network/GitStatus.swift
git commit -m "a9: GitStatus emits .projectFileDelta on count change"
```

---

## Task 11: Wire UserIdleTracker into Watchdog

**Files:**
- Modify: `Sources/Core/Watchdog.swift`

**Step 1: Read `Sources/Core/Watchdog.swift`** to locate `tick()` and the init signature.

**Step 2: Add an optional tracker property** and poll it once per tick:

```swift
// Property on the Watchdog type:
var userIdleTracker: UserIdleTracker? = nil

// Inside tick(), at the very top (or bottom — order doesn't matter):
userIdleTracker?.poll()
```

**Step 3: Build**

```bash
swift build
```

Expected: succeeds.

**Step 4: Commit**

```bash
git add Sources/Core/Watchdog.swift
git commit -m "a9: Watchdog.tick() polls UserIdleTracker"
```

---

## Task 12: Instantiate tracker + collector in AppDelegate, bind to Defaults

**Files:**
- Modify: `Sources/App/AppDelegate.swift`

**Step 1: Read `Sources/App/AppDelegate.swift`** to locate where `SessionManager` and `Watchdog` are created (likely inside `applicationDidFinishLaunching`).

**Step 2: Add tracker + collector instantiation** right after those, before the HTTP server starts:

```swift
// Properties on AppDelegate:
private var userIdleTracker: UserIdleTracker!
private var awayDigestCollector: AwayDigestCollector!

// Inside applicationDidFinishLaunching, after sessionManager + watchdog exist:

let enabled = UserDefaults.standard.object(forKey: DefaultsKey.awayDigestEnabled.rawValue) as? Bool ?? true
let thresholdMins = (UserDefaults.standard.object(forKey: DefaultsKey.awayDigestThresholdMins.rawValue) as? Int) ?? 10

userIdleTracker = UserIdleTracker()
userIdleTracker.enabled = enabled
userIdleTracker.thresholdSecs = TimeInterval(max(3, min(60, thresholdMins)) * 60)
watchdog.userIdleTracker = userIdleTracker

awayDigestCollector = AwayDigestCollector(sessionManager: sessionManager)
awayDigestCollector.enabled = enabled
```

**NOTE:** Replace `DefaultsKey.awayDigestEnabled.rawValue` with the actual key-string accessor used in `Defaults.swift` (may be `.awayDigestEnabled.stringKey` or similar — match the project's pattern when you see the file).

**Step 3: Expose the collector** as a public property (or via an environment object) so views can read it. The existing `SessionManager` is already wired this way — mirror that pattern exactly.

**Step 4: Build**

```bash
swift build
```

Expected: succeeds.

**Step 5: Commit**

```bash
git add Sources/App/AppDelegate.swift
git commit -m "a9: instantiate tracker + collector in AppDelegate, bind to Defaults"
```

---

## Task 13: Pure tooltip-text renderer + tests

**Files:**
- Create: `Sources/Views/ProjectDigestTooltip.swift`
- Create: `Tests/ProjectDigestTooltipTests.swift`

**Step 1: Write the failing tests first**

```swift
import XCTest
@testable import SnorOhSwift

final class ProjectDigestTooltipTests: XCTestCase {

    func makeSnap(tasks: Int = 0, secs: UInt64 = 0, files: Int = 0, sessions: Int = 0) -> DigestSnapshot {
        // Build a ProjectDigest of the right shape, then snapshot.
        var d = ProjectDigest(
            projectPath: "/tmp/proj",
            awayWindowStart: Date(timeIntervalSince1970: 1_000_000),
            awayWindowEnd: nil,
            events: []
        )
        for _ in 0..<tasks {
            d.append(ProjectEvent(kind: .task, timestamp: Date(timeIntervalSince1970: 1_000_060),
                                  durationSecs: secs / UInt64(max(tasks, 1)), filesDelta: 0))
        }
        if files != 0 {
            d.append(ProjectEvent(kind: .filesChanged, timestamp: Date(timeIntervalSince1970: 1_000_100),
                                  durationSecs: 0, filesDelta: files))
        }
        for _ in 0..<sessions {
            d.append(ProjectEvent(kind: .sessionEnded, timestamp: Date(timeIntervalSince1970: 1_000_200),
                                  durationSecs: 0, filesDelta: 0))
        }
        return DigestSnapshot(from: d, windowEnd: Date(timeIntervalSince1970: 1_000_300))
    }

    func testFeatureDisabledReturnsEmpty() {
        let snap = makeSnap(tasks: 1, secs: 60)
        XCTAssertEqual(tooltipText(snapshot: snap, enabled: false), "")
    }

    func testNoSnapshotReturnsEmpty() {
        XCTAssertEqual(tooltipText(snapshot: nil, enabled: true), "")
    }

    func testTasksOnly() {
        let snap = makeSnap(tasks: 2, secs: 480)  // 8 minutes total
        let txt = tooltipText(snapshot: snap, enabled: true)
        XCTAssertTrue(txt.contains("2 tasks completed"))
        XCTAssertTrue(txt.contains("8m"))
    }

    func testFilesOnly() {
        let snap = makeSnap(files: 3)
        let txt = tooltipText(snapshot: snap, enabled: true)
        XCTAssertTrue(txt.contains("3 files changed"))
    }

    func testTasksAndFiles() {
        let snap = makeSnap(tasks: 1, secs: 120, files: 5)
        let txt = tooltipText(snapshot: snap, enabled: true)
        XCTAssertTrue(txt.contains("1 task"))
        XCTAssertTrue(txt.contains("5 files"))
    }

    func testHeaderIncludesWindowRange() {
        let snap = makeSnap(tasks: 1, secs: 60)
        let txt = tooltipText(snapshot: snap, enabled: true)
        XCTAssertTrue(txt.contains("While you were away"))
    }
}
```

**Step 2: Run them** to confirm they fail (no `tooltipText` function).

```bash
swift test --filter SnorOhSwiftTests.ProjectDigestTooltipTests
```

Expected: compile error.

**Step 3: Implement** — `Sources/Views/ProjectDigestTooltip.swift`:

```swift
import Foundation

/// Pure function. Safe to call at render time — no IO, no allocations beyond
/// the returned string. Returns "" when disabled or no snapshot.
func tooltipText(snapshot: DigestSnapshot?, enabled: Bool) -> String {
    guard enabled, let s = snapshot else { return "" }

    let df = DateFormatter()
    df.dateFormat = "HH:mm"
    let range = "\(df.string(from: s.awayWindowStart))–\(df.string(from: s.awayWindowEnd))"

    var lines = ["While you were away (\(range)):"]
    var anyContent = false

    if s.taskCount > 0 {
        let mins = max(1, Int(s.totalTaskSecs / 60))
        lines.append("▲ \(s.taskCount) task\(s.taskCount == 1 ? "" : "s") completed · \(mins)m total")
        anyContent = true
    }
    if s.filesDelta != 0 {
        let n = abs(s.filesDelta)
        lines.append("▲ \(n) file\(n == 1 ? "" : "s") changed")
        anyContent = true
    }
    if s.sessionsEnded > 0 {
        lines.append("● \(s.sessionsEnded) session\(s.sessionsEnded == 1 ? "" : "s") ended")
        anyContent = true
    }
    if !anyContent {
        lines.append("no activity on this project")
    }
    if let last = s.lastActivity {
        lines.append("Last active: \(df.string(from: last))")
    }
    return lines.joined(separator: "\n")
}
```

**Step 4: Run tests**

```bash
swift test --filter SnorOhSwiftTests.ProjectDigestTooltipTests
```

Expected: all pass.

**Step 5: Commit**

```bash
git add Sources/Views/ProjectDigestTooltip.swift Tests/ProjectDigestTooltipTests.swift
git commit -m "a9: ProjectDigestTooltip pure renderer (TDD)"
```

---

## Task 14: Attach `.help()` + "Clear digest" menu item to project row

**Files:**
- Modify: `Sources/Views/SnorOhPanelView.swift` (function `projectRow(_:)` starting line ~384)

**Step 1: Expose the collector to the view.** Add an `@Environment` or `@Bindable` reference to `AwayDigestCollector` alongside the existing `sessionManager` reference in `SnorOhPanelView`. Match the existing pattern exactly (look at how `BucketManager` is exposed — it's the cleanest existing precedent).

**Step 2: Compute and apply tooltip** inside `projectRow(_:)`, after the existing `HStack` and `.background(...)` but before `.onTapGesture`:

```swift
.help(
    tooltipText(
        snapshot: awayDigestCollector.snapshot(for: project.path),
        enabled: awayDigestCollector.enabled
    )
)
```

**Step 3: Add "Clear digest" to the `.contextMenu`**, gated on non-empty snapshot:

```swift
.contextMenu {
    Button("Open in VS Code") { openInVSCode(path: project.path) }
    Button("Open in Terminal") { openInTerminal(path: project.path) }
    Button("Reveal in Finder") {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.path)
    }
    Divider()
    Button("Copy Path") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(project.path, forType: .string)
    }
    if awayDigestCollector.snapshot(for: project.path) != nil {
        Divider()
        Button("Clear digest") {
            awayDigestCollector.clearDigest(for: project.path)
        }
    }
}
```

**Step 4: Build**

```bash
swift build
```

Expected: succeeds.

**Step 5: Commit**

```bash
git add Sources/Views/SnorOhPanelView.swift
git commit -m "a9: project row tooltip + clear-digest context action"
```

---

## Task 15: Welcome-back bubble handler

**Files:**
- Modify: `Sources/Views/SpeechBubble.swift` (look for the `BubbleManager` type)

**Step 1: Read `Sources/Views/SpeechBubble.swift`** to understand how task-completion bubbles are posted today. The existing pattern uses `NotificationCenter` + `BubbleManager.post(message:, dismissAfter:)`.

**Step 2: Add a `.userReturned` observer** to `BubbleManager` (matching the existing observer setup for `.taskCompleted`):

```swift
// In BubbleManager's init / setupObservers():
NotificationCenter.default.addObserver(
    forName: .userReturned, object: nil, queue: .main
) { [weak self] _ in
    self?.handleUserReturned()
}

// New method:
private func handleUserReturned() {
    // Grab the collector from wherever BubbleManager already sources its
    // dependencies (the existing task-completion handler has a path to the
    // SessionManager; reuse it). If BubbleManager doesn't have access to
    // AwayDigestCollector, inject it the same way SessionManager is injected.
    guard let msg = awayDigestCollector?.welcomeBackSummary() else { return }
    post(message: msg, dismissAfter: 8.0)
}
```

**NOTE:** If `BubbleManager` doesn't already have a reference to the collector, the cleanest wire-up is to set it in `AppDelegate.applicationDidFinishLaunching` right after creating the collector (add a property on `BubbleManager`). Don't refactor — match existing dependency-injection style.

**Step 3: Build**

```bash
swift build
```

Expected: succeeds.

**Step 4: Manual smoke test (skip in CI):** with the app running, post a `.userAwayStarted` notification via the debugger, post a `.taskCompleted` with a valid pid/cwd, post `.userReturned` — bubble should appear with the expected copy.

**Step 5: Commit**

```bash
git add Sources/Views/SpeechBubble.swift Sources/App/AppDelegate.swift
git commit -m "a9: welcome-back speech bubble on .userReturned"
```

---

## Task 16: Settings → General UI (toggle + slider)

**Files:**
- Modify: `Sources/Views/SettingsView.swift`

**Step 1: Read `Sources/Views/SettingsView.swift`** to find the General tab and an existing toggle (bubbles / glow / auto-start are all there) to copy the layout idiom.

**Step 2: Add a new section** beneath the existing toggles:

```swift
// In the General tab body:

Divider()

VStack(alignment: .leading, spacing: 8) {
    Toggle("Away digest", isOn: $awayDigestEnabled)
    Text("Summarize what happened in each project while you were away. Hover a project row to read the digest; a bubble appears when you return.")
        .font(.caption)
        .foregroundStyle(.secondary)

    if awayDigestEnabled {
        HStack {
            Text("Idle threshold")
            Slider(value: Binding(
                get: { Double(awayDigestThresholdMins) },
                set: { awayDigestThresholdMins = Int($0) }
            ), in: 3...60, step: 1)
            Text("\(awayDigestThresholdMins) min")
                .monospacedDigit()
                .frame(width: 56, alignment: .trailing)
        }
    }
}
.padding(.vertical, 4)
```

**Step 3: Declare bindings backed by UserDefaults.** At the top of `SettingsView`:

```swift
@AppStorage(DefaultsKey.awayDigestEnabled.rawValue) private var awayDigestEnabled: Bool = true
@AppStorage(DefaultsKey.awayDigestThresholdMins.rawValue) private var awayDigestThresholdMins: Int = 10
```

Match the file's existing `@AppStorage` patterns exactly (string constant vs `DefaultsKey` accessor — whichever is used by the neighboring bubbles/glow toggles).

**Step 4: Wire live-effectiveness.** The Settings panel should mutate `UserIdleTracker.enabled`, `UserIdleTracker.thresholdSecs`, and `AwayDigestCollector.enabled` on change — the simplest path is an `.onChange(of:)` on both bindings that calls an AppDelegate method like `applyAwayDigestSettings(enabled:thresholdMins:)`. Add that AppDelegate method; it assigns the three fields.

```swift
.onChange(of: awayDigestEnabled) { _, new in
    (NSApp.delegate as? AppDelegate)?.applyAwayDigestSettings(
        enabled: new, thresholdMins: awayDigestThresholdMins
    )
}
.onChange(of: awayDigestThresholdMins) { _, new in
    (NSApp.delegate as? AppDelegate)?.applyAwayDigestSettings(
        enabled: awayDigestEnabled, thresholdMins: new
    )
}
```

In `AppDelegate`:

```swift
func applyAwayDigestSettings(enabled: Bool, thresholdMins: Int) {
    let clamped = max(3, min(60, thresholdMins))
    userIdleTracker?.enabled = enabled
    userIdleTracker?.thresholdSecs = TimeInterval(clamped * 60)
    awayDigestCollector?.enabled = enabled
}
```

**Step 5: Build + launch**

```bash
swift build && swift run
```

Toggle the checkbox and slider in Settings → General. Confirm no crash and that values persist after relaunch.

**Step 6: Commit**

```bash
git add Sources/Views/SettingsView.swift Sources/App/AppDelegate.swift
git commit -m "a9: Settings General toggle + threshold slider (live-effective)"
```

---

## Task 17: Manual end-to-end verification

**No code changes.** This is a walk-through to catch anything missed in tests.

**Step 1: Release build**

```bash
bash Scripts/build-release.sh
open .build/release-app/snor-oh.app
```

**Step 2: Smoke checklist**

- [ ] App launches without new log noise or crashes
- [ ] Settings → General shows "Away digest" checkbox + threshold slider, reflecting current Defaults
- [ ] With the checkbox ON and threshold set to 3 minutes: open Claude Code in one terminal, run a short task, step away for 4 min (genuinely — no mouse, no keys), come back. A speech bubble should appear summarizing what happened.
- [ ] Hover a project row in the panel — tooltip shows the digest text with time range.
- [ ] Step away again while no sessions are busy. On return: NO bubble (zero activity).
- [ ] Toggle checkbox OFF. Tooltip disappears instantly on next hover; next away window does not fire a bubble.
- [ ] Right-click a project row with a non-empty digest → "Clear digest" appears and clears.
- [ ] Run the full test suite: `swift test`. Expected: all pass.

**Step 3: If any checklist item fails**, open a specific bugfix task — do not paper over. Fix, re-run the checklist from the top.

**Step 4: Final commit** (only if tiny polish fixes were needed)

```bash
git add -p
git commit -m "a9: manual-verification follow-ups"
```

---

## Task 18: Update PRD + roadmap status

**Files:**
- Modify: `docs/prd/A9-away-digest.md` — convert rollout-plan checkboxes to ✅
- Modify: `docs/prd/buddy-roadmap.md` — move A9 from landscape to "Shipped" in §1 when all verification passes

**Step 1: Mark rollout items done** in A9 PRD (one-line edits on each row).

**Step 2: Add A9 to §1 "Shipped"** block in `buddy-roadmap.md`:

```markdown
- **A9 Away digest** — per-project tooltip + welcome-back bubble on real user-idle return
```

**Step 3: Commit**

```bash
git add docs/prd/A9-away-digest.md docs/prd/buddy-roadmap.md
git commit -m "a9: mark shipped in PRD + roadmap"
```

---

## Recap: complete commit sequence

```
a9: add awayDigestEnabled + threshold Defaults keys                (Task 1)
a9: declare userAwayStarted/userReturned/projectFileDelta ...      (Task 2)
a9: add ProjectDigest value types + snapshot rollup                (Task 3)
a9: add IdleSecondsProvider + SystemIdleProvider                   (Task 4)
a9: UserIdleTracker state machine + hysteresis (TDD)               (Task 5-6)
a9: AwayDigestCollector with per-project accumulation ...          (Task 7-8)
a9: include pid in .taskCompleted userInfo (additive)              (Task 9)
a9: GitStatus emits .projectFileDelta on count change              (Task 10)
a9: Watchdog.tick() polls UserIdleTracker                          (Task 11)
a9: instantiate tracker + collector in AppDelegate, bind to ...    (Task 12)
a9: ProjectDigestTooltip pure renderer (TDD)                       (Task 13)
a9: project row tooltip + clear-digest context action              (Task 14)
a9: welcome-back speech bubble on .userReturned                    (Task 15)
a9: Settings General toggle + threshold slider (live-effective)    (Task 16)
a9: manual-verification follow-ups                                 (Task 17)
a9: mark shipped in PRD + roadmap                                  (Task 18)
```

16 commits (tasks 5-6 and 7-8 are each one commit). Each commit is independently buildable — no broken intermediate state. This lets you bisect later if a regression slips in.

## Open questions carried forward

The PRD's open questions (§Open Questions) are not blocking — ship defaults, revisit post-ship. If a question blocks a specific task, stop and resolve with the user before implementing:

- Accessibility: mirror `.help()` into `.accessibilityHint(...)` on the row — small, add in Task 14 if trivial.
- Peer-visitor events in tooltip: out of scope for v1, do not add.
- Bubble suppression on immediate panel open: defer to post-ship polish.
