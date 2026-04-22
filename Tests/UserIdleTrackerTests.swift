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

    func testAwayDurationClampedForSystemSleep() {
        let t = UserIdleTracker()
        let mock = MockIdleProvider()
        mock.script = [600, 8 * 60 * 60, 0]  // present, then "returned from 8h sleep"
        t.provider = mock
        t.thresholdSecs = 300
        t.maxReportableAwaySecs = 2 * 60 * 60  // 2h explicit

        let ret = observe(.userReturned)

        t.poll()  // 600 -> away
        t.poll()  // 8h -> still away (not below hysteresis)
        t.poll()  // 0   -> return

        XCTAssertEqual(ret.count(), 1)
        let dur = ret.latest()?["away_duration_secs"] as? UInt64
        XCTAssertNotNil(dur)
        XCTAssertLessThanOrEqual(dur ?? 0, UInt64(2 * 60 * 60),
            "awayDuration must be clamped at maxReportableAwaySecs")
    }
}
