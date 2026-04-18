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

    func testHeartbeatUpdatesLastSeen() {
        let sm = SessionManager()
        sm.handleStatus(pid: 1, state: "busy", type: "task", cwd: "/tmp")
        let firstSeen = sm.sessions[1]?.lastSeen ?? 0

        // Heartbeat should NOT update last_seen for busy sessions
        sm.handleHeartbeat(pid: 1, cwd: nil)
        let afterHeartbeat = sm.sessions[1]?.lastSeen ?? 0
        XCTAssertEqual(firstSeen, afterHeartbeat)
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
}
