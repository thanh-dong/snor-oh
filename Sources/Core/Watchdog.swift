import Foundation

/// Background timer that runs every 2 seconds to handle:
/// - Service → Idle transitions (after 2s display time)
/// - Stale session cleanup (40s heartbeat timeout)
/// - Visitor expiration
/// - Idle → Sleep transition (120s idle)
final class Watchdog {
    private var timer: Timer?
    private let sessionManager: SessionManager
    var userIdleTracker: UserIdleTracker? = nil

    init(sessionManager: SessionManager) {
        self.sessionManager = sessionManager
    }

    func start() {
        // Use Timer() + add to .common mode (not scheduledTimer which adds to .default,
        // causing double-fire if we then also add to .common)
        let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.userIdleTracker?.poll()
            self?.sessionManager.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}
