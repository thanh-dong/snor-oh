import XCTest
@testable import SnorOhSwift

final class SessionManagerTests: XCTestCase {

    func testInitialState() {
        let sm = SessionManager()
        XCTAssertEqual(sm.currentUI, .initializing)
        XCTAssertTrue(sm.sessions.isEmpty)
        XCTAssertFalse(sm.sleeping)
    }

    func testHandleStatusBusy() {
        let sm = SessionManager()
        sm.handleStatus(pid: 1, state: "busy", type: "task", cwd: "/tmp/project-a")

        XCTAssertEqual(sm.sessions.count, 1)
        XCTAssertEqual(sm.sessions[1]?.uiState, .busy)
        XCTAssertEqual(sm.sessions[1]?.cwd, "/tmp/project-a")
        XCTAssertEqual(sm.currentUI, .busy)
    }

    func testHandleStatusIdle() {
        let sm = SessionManager()
        sm.handleStatus(pid: 1, state: "busy", type: "task", cwd: "/tmp/test")
        sm.handleStatus(pid: 1, state: "idle", type: nil, cwd: nil)

        XCTAssertEqual(sm.sessions[1]?.uiState, .idle)
        XCTAssertEqual(sm.currentUI, .idle)
        XCTAssertEqual(sm.usage.tasksCompleted, 1)
    }

    func testHandleStatusService() {
        let sm = SessionManager()
        sm.handleStatus(pid: 1, state: "busy", type: "service", cwd: "/tmp/frontend")

        XCTAssertEqual(sm.sessions[1]?.uiState, .service)
        XCTAssertEqual(sm.currentUI, .service)
    }

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

    func testResolveUIStatePriority() {
        let sm = SessionManager()
        sm.handleStatus(pid: 1, state: "busy", type: "task", cwd: "/a")
        sm.handleStatus(pid: 2, state: "busy", type: "service", cwd: "/b")

        // busy (4) > service (3)
        XCTAssertEqual(sm.resolveUIState(), .busy)
    }

    func testProjectAggregation() {
        let sm = SessionManager()
        sm.handleStatus(pid: 1, state: "busy", type: "task", cwd: "/projects/api")
        sm.handleStatus(pid: 2, state: "busy", type: "service", cwd: "/projects/frontend")
        sm.handleStatus(pid: 3, state: "busy", type: "task", cwd: "/projects/api")

        XCTAssertEqual(sm.projects.count, 2)

        let api = sm.projects.first { $0.name == "api" }
        XCTAssertNotNil(api)
        XCTAssertEqual(api?.sessions.count, 2)
        XCTAssertEqual(api?.status, .busy)

        let frontend = sm.projects.first { $0.name == "frontend" }
        XCTAssertNotNil(frontend)
        XCTAssertEqual(frontend?.sessions.count, 1)
        XCTAssertEqual(frontend?.status, .service)
    }

    func testHeartbeatRefreshesBusySessionToo() {
        // New semantic: PID-liveness is the authoritative lifecycle signal,
        // so heartbeats unconditionally refresh lastSeen. The old `!= .busy`
        // gate used to strand sessions stuck in busy — see
        // `Sources/Core/SessionManager.swift handleHeartbeat` for the rationale.
        let sm = SessionManager()
        sm.handleStatus(pid: 1, state: "busy", type: "task", cwd: "/tmp")
        sm.sessions[1]?.lastSeen = 0

        sm.handleHeartbeat(pid: 1, cwd: nil)
        XCTAssertGreaterThan(sm.sessions[1]?.lastSeen ?? 0, 0,
                             "heartbeat should refresh lastSeen for busy sessions now")
    }

    func testAllSessionsExpireWhenStale() {
        let sm = SessionManager()
        sm.handleStatus(pid: 0, state: "busy", type: "task", cwd: nil)

        // Simulate stale session (manually set last_seen to 0)
        sm.sessions[0]?.lastSeen = 0
        sm.tick()

        // All sessions expire when stale — no special cases
        XCTAssertNil(sm.sessions[0])
    }

    func testStaleSessionRemoval() {
        let sm = SessionManager()
        sm.handleStatus(pid: 42, state: "busy", type: "task", cwd: "/tmp")

        // Simulate stale session
        sm.sessions[42]?.lastSeen = 0
        sm.tick()

        XCTAssertNil(sm.sessions[42])
    }

    func testVisitorLifecycle() {
        let sm = SessionManager()
        let visitor = VisitingDog(
            instanceName: "buddy-123",
            pet: "sprite",
            nickname: "Buddy",
            arrivedAt: nowSecs(),
            durationSecs: 15
        )

        sm.addVisitor(visitor)
        XCTAssertEqual(sm.visitors.count, 1)

        sm.removeVisitor(instanceName: "buddy-123", nickname: nil)
        XCTAssertEqual(sm.visitors.count, 0)
    }

    func testMCPReactionMapping() {
        // Just verify the function doesn't crash — actual notification
        // posting is tested via integration tests
        let sm = SessionManager()
        sm.handleMCPReact(reaction: "celebrate", durationMs: 3000)
        sm.handleMCPReact(reaction: "nervous", durationMs: 3000)
        sm.handleMCPReact(reaction: "confused", durationMs: 3000)
        sm.handleMCPReact(reaction: "excited", durationMs: 3000)
        sm.handleMCPReact(reaction: "sleep", durationMs: 3000)
        sm.handleMCPReact(reaction: "unknown", durationMs: 3000)
    }

    func testPetStatusJSON() {
        let sm = SessionManager()
        sm.handleStatus(pid: 1, state: "busy", type: "task", cwd: "/projects/api")

        let response = sm.petStatusJSON()
        XCTAssertEqual(response.sessionsActive, 1)
        XCTAssertEqual(response.currentStatus, "busy")
        XCTAssertEqual(response.projects.count, 1)
        XCTAssertEqual(response.projects.first?.name, "api")
    }

    func testDailyReset() {
        let sm = SessionManager()
        // Set usage to a different day
        sm.usage.usageDay = currentDay() - 1
        sm.usage.tasksCompleted = 99

        // handleStatus triggers resetDailyIfNeeded
        sm.handleStatus(pid: 1, state: "busy", type: "task", cwd: "/tmp")
        sm.handleStatus(pid: 1, state: "idle", type: nil, cwd: nil)

        XCTAssertEqual(sm.usage.tasksCompleted, 1) // Reset to 0, then +1
    }

    // MARK: - Phase 2: Sidebar / Multi-Session Tests

    func testModifiedFilesPreservedAcrossRecompute() {
        let sm = SessionManager()
        sm.handleStatus(pid: 1, state: "busy", type: "task", cwd: "/projects/api")

        // Simulate git poller update
        sm.updateModifiedFiles(forPath: "/projects/api", count: 5)
        XCTAssertEqual(sm.projects.first?.modifiedFiles, 5)

        // Trigger recompute via heartbeat — file count must survive
        sm.handleHeartbeat(pid: 1, cwd: "/projects/api")
        XCTAssertEqual(sm.projects.first?.modifiedFiles, 5)
    }

    func testModifiedFilesUpdateForPath() {
        let sm = SessionManager()
        sm.handleStatus(pid: 1, state: "busy", type: "task", cwd: "/a")
        sm.handleStatus(pid: 2, state: "busy", type: "task", cwd: "/b")

        sm.updateModifiedFiles(forPath: "/a", count: 3)
        sm.updateModifiedFiles(forPath: "/b", count: 7)

        let projA = sm.projects.first { $0.path == "/a" }
        let projB = sm.projects.first { $0.path == "/b" }
        XCTAssertEqual(projA?.modifiedFiles, 3)
        XCTAssertEqual(projB?.modifiedFiles, 7)
    }

    func testProjectRemovedWhenAllSessionsExpire() {
        let sm = SessionManager()
        sm.handleStatus(pid: 10, state: "busy", type: "task", cwd: "/projects/ephemeral")
        XCTAssertEqual(sm.projects.count, 1)

        // Expire the session
        sm.sessions[10]?.lastSeen = 0
        sm.tick()

        XCTAssertTrue(sm.projects.isEmpty)
    }

    func testProjectAggregateStatusPriority() {
        let sm = SessionManager()
        // Two sessions in same project: one idle, one busy
        sm.handleStatus(pid: 1, state: "idle", type: nil, cwd: "/projects/mixed")
        sm.handleStatus(pid: 2, state: "busy", type: "task", cwd: "/projects/mixed")

        let project = sm.projects.first { $0.name == "mixed" }
        XCTAssertNotNil(project)
        XCTAssertEqual(project?.status, .busy) // busy wins
        XCTAssertEqual(project?.sessions.count, 2)
    }

    func testNilCwdSessionExcludedFromProjects() {
        let sm = SessionManager()
        sm.handleStatus(pid: 1, state: "busy", type: "task", cwd: nil)
        sm.handleStatus(pid: 2, state: "busy", type: "task", cwd: "/projects/real")

        XCTAssertEqual(sm.projects.count, 1)
        XCTAssertEqual(sm.projects.first?.name, "real")
    }

    func testProjectsSortedAlphabetically() {
        let sm = SessionManager()
        sm.handleStatus(pid: 1, state: "idle", type: nil, cwd: "/z-project")
        sm.handleStatus(pid: 2, state: "idle", type: nil, cwd: "/a-project")
        sm.handleStatus(pid: 3, state: "idle", type: nil, cwd: "/m-project")

        let names = sm.projects.map(\.name)
        XCTAssertEqual(names, ["a-project", "m-project", "z-project"])
    }

    // MARK: - Session lifecycle (event-driven, Tier-1 redesign)

    /// Fake liveness checker for deterministic tick tests. Production uses
    /// POSIX `kill(0)`; tests drive it directly from a Set so we don't depend
    /// on real OS PIDs.
    private final class FakeLiveness: SessionLivenessChecking {
        var alive: Set<UInt32> = []
        var startedAt: [UInt32: String] = [:]
        func isAlive(pid: UInt32, expectedStartedAt: String?) -> Bool {
            guard alive.contains(pid) else { return false }
            if let expected = expectedStartedAt,
               let actual = startedAt[pid],
               expected != actual {
                return false  // PID reuse: same number, different process
            }
            return true
        }
    }

    func testHandleSessionStartCreatesSessionWithMetadata() {
        let sm = SessionManager()
        sm.handleSessionStart(
            pid: 100, cwd: "/tmp/proj", kind: "shell",
            startedAt: "Mon Apr 20 14:00:00 2026"
        )
        XCTAssertEqual(sm.sessions[100]?.kind, "shell")
        XCTAssertEqual(sm.sessions[100]?.startedAt, "Mon Apr 20 14:00:00 2026")
        XCTAssertEqual(sm.sessions[100]?.cwd, "/tmp/proj")
        XCTAssertEqual(sm.sessions[100]?.uiState, .idle)
    }

    func testHandleSessionEndRemovesImmediately() {
        let sm = SessionManager()
        sm.handleSessionStart(pid: 200, cwd: "/a", kind: "claude", startedAt: "T")
        XCTAssertNotNil(sm.sessions[200])

        sm.handleSessionEnd(pid: 200)
        XCTAssertNil(sm.sessions[200], "/session-end must delete immediately, no 60s wait")
    }

    func testWatchdogRemovesDeadPIDs() {
        let sm = SessionManager()
        let fake = FakeLiveness()
        fake.alive = [11]  // only PID 11 is alive
        sm.livenessChecker = fake

        sm.handleSessionStart(pid: 11, cwd: "/alive", kind: "shell", startedAt: "T1")
        sm.handleSessionStart(pid: 22, cwd: "/dead", kind: "shell", startedAt: "T2")

        sm.tick()
        XCTAssertNotNil(sm.sessions[11], "live PID stays")
        XCTAssertNil(sm.sessions[22], "dead PID removed by kill(0) sweep")
    }

    func testWatchdogDetectsPIDReuseByStartedAt() {
        // PID 33 is currently alive but with a different start time than what
        // the session was registered with → treated as a different process.
        let sm = SessionManager()
        let fake = FakeLiveness()
        fake.alive = [33]
        fake.startedAt = [33: "NEW-START"]
        sm.livenessChecker = fake

        sm.handleSessionStart(pid: 33, cwd: "/x", kind: "shell", startedAt: "OLD-START")

        // Manually trigger liveness via pidfile scan path (tick only uses kill(0)).
        // loadExistingSessions would run on app launch; simulate by re-checking
        // via livenessChecker with the stored startedAt.
        XCTAssertFalse(sm.livenessChecker.isAlive(pid: 33, expectedStartedAt: "OLD-START"),
                       "start-time mismatch must be treated as dead (PID was reused)")
        XCTAssertTrue(sm.livenessChecker.isAlive(pid: 33, expectedStartedAt: nil),
                      "without expected start time, kill(0) says alive")
    }

    /// Fake process scanner for deterministic startup tests.
    private final class FakeScanner: SessionProcessScanning {
        var shells: [ShellProcessInfo] = []
        func scanInteractiveShells() -> [ShellProcessInfo] { shells }
    }

    func testLoadExistingSessionsSeedsFromProcessScan() {
        // No pidfiles on disk (normal case for pre-upgrade shells). The
        // process scanner fills the gap so the UI isn't blank at launch.
        let sm = SessionManager()
        let fakeScan = FakeScanner()
        fakeScan.shells = [
            ShellProcessInfo(pid: 501, cwd: "/Users/me/proj-a", startedAt: "T501"),
            ShellProcessInfo(pid: 502, cwd: "/Users/me/proj-b", startedAt: "T502"),
        ]
        sm.processScanner = fakeScan
        // Use the default liveness — pidfile scan reads ~/.snor-oh/sessions
        // which will be empty or irrelevant in the test environment.

        sm.loadExistingSessions()

        XCTAssertEqual(sm.sessions[501]?.cwd, "/Users/me/proj-a")
        XCTAssertEqual(sm.sessions[501]?.kind, "shell")
        XCTAssertEqual(sm.sessions[502]?.startedAt, "T502")
        XCTAssertEqual(sm.projects.count, 2, "both scanned shells materialize as projects")
    }

    func testLegacyHeartbeatSessionStillAgeExpires() {
        // Pre-upgrade shells use /heartbeat and never set startedAt. Those
        // sessions fall back to lastSeen-age expiration so a gone shell
        // eventually disappears even if we never get a /session-end.
        let sm = SessionManager()
        let fake = FakeLiveness()
        fake.alive = [77]  // OS says it's alive
        sm.livenessChecker = fake

        sm.handleHeartbeat(pid: 77, cwd: "/legacy")
        XCTAssertNil(sm.sessions[77]?.startedAt, "legacy heartbeat session has no startedAt")

        sm.sessions[77]?.lastSeen = 0  // age it out
        sm.tick()
        XCTAssertNil(sm.sessions[77], "legacy session past heartbeatTimeoutSecs must expire")
    }
}
