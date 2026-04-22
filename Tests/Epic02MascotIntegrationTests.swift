import XCTest
@testable import SnorOhSwift

/// Epic 02 — mascot integration unit tests. Cover:
///   - `.carrying` status priority + display resolver
///   - Badge text formatter
///   - Heavy-threshold detector (pure + round-trip through BucketManager)
///   - Reset-on-drain semantics so a cleared bucket warns again
///
/// Uses isolated temp-dir BucketStore so each test gets a fresh state.
@MainActor
final class Epic02MascotIntegrationTests: XCTestCase {

    // MARK: - Status.carrying

    func testCarryingPriorityBetweenIdleAndService() {
        XCTAssertGreaterThan(Status.carrying.priority, Status.idle.priority,
                             "carrying must outrank idle so pet shows it when quiet")
        XCTAssertLessThan(Status.carrying.priority, Status.service.priority,
                          "service (MCP react, etc.) must win over carrying")
        XCTAssertLessThan(Status.carrying.priority, Status.busy.priority,
                          "Claude Code busy work must always win over carrying")
    }

    func testCarryingRawValueStable() {
        // Stability guard: status raw values hit disk via UserDefaults /
        // PetStatusResponse JSON, so renaming the case would break clients.
        XCTAssertEqual(Status.carrying.rawValue, "carrying")
    }

    func testResolveDisplayEmptyBucketReturnsSessionStatus() {
        for status in Status.allCases {
            XCTAssertEqual(
                Status.resolveDisplay(sessionStatus: status, bucketCount: 0),
                status,
                "empty bucket must never change the sprite status (got \(status))"
            )
        }
    }

    func testResolveDisplayPromotesIdleToCarrying() {
        XCTAssertEqual(
            Status.resolveDisplay(sessionStatus: .idle, bucketCount: 1),
            .carrying
        )
    }

    func testResolveDisplayDoesNotOverrideBusyOrService() {
        XCTAssertEqual(
            Status.resolveDisplay(sessionStatus: .busy, bucketCount: 5),
            .busy,
            "Claude Code busy must never be masked by carrying"
        )
        XCTAssertEqual(
            Status.resolveDisplay(sessionStatus: .service, bucketCount: 5),
            .service
        )
    }

    func testResolveDisplayPromotesDisconnectedToCarrying() {
        // Pet is asleep but bucket has stuff → wake to carrying so the user
        // sees their stash hasn't been forgotten.
        XCTAssertEqual(
            Status.resolveDisplay(sessionStatus: .disconnected, bucketCount: 2),
            .carrying
        )
    }

    // MARK: - Badge text formatter

    func testBadgeTextHiddenAtZero() {
        XCTAssertNil(BucketManager.badgeText(count: 0))
    }

    func testBadgeTextDisplaysRawCountUpTo99() {
        XCTAssertEqual(BucketManager.badgeText(count: 1), "1")
        XCTAssertEqual(BucketManager.badgeText(count: 5), "5")
        XCTAssertEqual(BucketManager.badgeText(count: 99), "99")
    }

    func testBadgeTextClampsAt99Plus() {
        XCTAssertEqual(BucketManager.badgeText(count: 100), "99+")
        XCTAssertEqual(BucketManager.badgeText(count: 1_000), "99+")
    }

    // MARK: - Crossed-threshold pure helper

    func testCrossedThresholdBelowLowestIsNil() {
        XCTAssertNil(BucketManager.crossedThreshold(count: 0, fired: []))
        XCTAssertNil(BucketManager.crossedThreshold(count: 19, fired: []))
    }

    func testCrossedThresholdAt20FiresTwenty() {
        XCTAssertEqual(BucketManager.crossedThreshold(count: 20, fired: []), 20)
        XCTAssertEqual(BucketManager.crossedThreshold(count: 21, fired: []), 20)
    }

    func testCrossedThresholdSkipsAlreadyFired() {
        XCTAssertNil(BucketManager.crossedThreshold(count: 21, fired: [20]))
    }

    func testCrossedThresholdPicksHighestUnfired() {
        // A bulk paste that lands the bucket at 55 items should fire the
        // "50" level (highest reached) rather than re-fire 20 step-by-step.
        XCTAssertEqual(BucketManager.crossedThreshold(count: 55, fired: []), 50)
    }

    func testCrossedThresholdRespectsHundred() {
        XCTAssertEqual(BucketManager.crossedThreshold(count: 100, fired: [20, 50]), 100)
    }

    // MARK: - BucketManager round-trip (bucketHeavy notification)

    func testHeavyNotificationFiresOnceAtTwenty() async {
        let (manager, tempRoot) = makeManager()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let exp = expectation(forNotification: .bucketHeavy, object: nil) { note in
            note.userInfo?["threshold"] as? Int == 20
        }
        for i in 0..<20 {
            manager.add(BucketItem(kind: .text, text: "item-\(i)"), source: .panel)
        }
        await fulfillment(of: [exp], timeout: 0.5)

        // Adding more shouldn't re-post the same threshold.
        let notRepeat = expectation(description: "no-repeat")
        notRepeat.isInverted = true
        let obs = NotificationCenter.default.addObserver(
            forName: .bucketHeavy, object: nil, queue: .main
        ) { note in
            if note.userInfo?["threshold"] as? Int == 20 { notRepeat.fulfill() }
        }
        defer { NotificationCenter.default.removeObserver(obs) }
        manager.add(BucketItem(kind: .text, text: "one-more"), source: .panel)
        await fulfillment(of: [notRepeat], timeout: 0.2)
    }

    func testHeavyNotificationReFiresAfterClearAndRefill() async {
        let (manager, tempRoot) = makeManager()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        // First fill → expect 20.
        let firstFire = expectation(forNotification: .bucketHeavy, object: nil) { note in
            note.userInfo?["threshold"] as? Int == 20
        }
        for i in 0..<20 {
            manager.add(BucketItem(kind: .text, text: "a-\(i)"), source: .panel)
        }
        await fulfillment(of: [firstFire], timeout: 0.5)

        // Drain via clearUnpinned — drops count below 20 and resets fired set.
        manager.clearUnpinned()
        XCTAssertEqual(manager.totalActiveItemCount(), 0)

        // Refill past 20 → must fire again.
        let secondFire = expectation(forNotification: .bucketHeavy, object: nil) { note in
            note.userInfo?["threshold"] as? Int == 20
        }
        for i in 0..<20 {
            manager.add(BucketItem(kind: .text, text: "b-\(i)"), source: .panel)
        }
        await fulfillment(of: [secondFire], timeout: 0.5)
    }

    func testTotalActiveItemCountExcludesArchived() {
        let (manager, tempRoot) = makeManager()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let secondID = manager.createBucket(name: "Second")
        manager.add(BucketItem(kind: .text, text: "active"), source: .panel)
        manager.add(BucketItem(kind: .text, text: "also-active"), source: .panel, toBucket: secondID)
        XCTAssertEqual(manager.totalActiveItemCount(), 2)

        manager.archiveBucket(id: secondID)
        XCTAssertEqual(manager.totalActiveItemCount(), 1,
                       "items in an archived bucket must not count toward the carrying badge")
    }

    // MARK: - Helpers

    private func makeManager() -> (BucketManager, URL) {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("epic02-test-\(UUID().uuidString)")
        let store = BucketStore(rootURL: tempRoot)
        return (BucketManager(store: store), tempRoot)
    }
}
