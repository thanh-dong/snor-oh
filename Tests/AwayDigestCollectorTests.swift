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
        NotificationCenter.default.post(
            name: .taskCompleted, object: nil,
            userInfo: ["duration_secs": UInt64(120), "pid": UInt32(1)]
        )
        XCTAssertNil(collector.digest(for: "/tmp/p"))
    }

    func testEventsDuringAwayAccumulate() {
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
