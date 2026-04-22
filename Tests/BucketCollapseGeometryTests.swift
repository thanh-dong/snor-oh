import XCTest
@testable import SnorOhSwift

/// Pure-math regression tests for the bucket's auto-collapse behavior.
/// Every test here locks down an invariant whose violation caused a bug in
/// v0.8.0 or the follow-up:
///
///   - "Bucket flashes on focus change" — tied to mid-animation frame reads
///     corrupting expandedHeight; guarded by `isEssentiallyCollapsed`.
///   - "Doesn't expand to original size" — top edge wasn't pinned across
///     the collapse/expand cycle.
///   - "Position inconsistent" — `origin.y` wasn't normalised back to the
///     expanded coordinate space before persistence.
final class BucketCollapseGeometryTests: XCTestCase {

    // MARK: - targetFrame keeps the top edge pinned

    func testCollapsePreservesTopEdge() {
        let current = CGRect(x: 100, y: 500, width: 320, height: 440)
        let originalTop = current.origin.y + current.height

        let target = BucketCollapseGeometry.targetFrame(
            current: current,
            targetHeight: 116
        )
        let newTop = target.origin.y + target.height

        XCTAssertEqual(target.size.height, 116)
        XCTAssertEqual(newTop, originalTop,
                       "Top edge must stay pinned while the bottom rises.")
    }

    func testExpandPreservesTopEdge() {
        let current = CGRect(x: 100, y: 824, width: 320, height: 116)
        let originalTop = current.origin.y + current.height

        let target = BucketCollapseGeometry.targetFrame(
            current: current,
            targetHeight: 440
        )
        let newTop = target.origin.y + target.height

        XCTAssertEqual(target.size.height, 440)
        XCTAssertEqual(newTop, originalTop,
                       "Top edge must stay pinned while the bottom falls.")
    }

    func testCollapseThenExpandIsIdentity() {
        // The canonical round-trip. Starting at expanded, collapsing, then
        // expanding must land the window exactly where it started —
        // otherwise the user experiences position drift every focus cycle.
        let start = CGRect(x: 200, y: 300, width: 320, height: 440)

        let collapsed = BucketCollapseGeometry.targetFrame(
            current: start,
            targetHeight: 116
        )
        let restored = BucketCollapseGeometry.targetFrame(
            current: collapsed,
            targetHeight: 440
        )

        XCTAssertEqual(restored.origin.x, start.origin.x)
        XCTAssertEqual(restored.origin.y, start.origin.y,
                       "round-trip must be an identity on origin.y")
        XCTAssertEqual(restored.size.width, start.size.width)
        XCTAssertEqual(restored.size.height, start.size.height)
    }

    func testCollapseToEqualHeightIsNoop() {
        // If targetHeight equals current.height, origin/size don't change.
        let current = CGRect(x: 100, y: 500, width: 320, height: 440)
        let same = BucketCollapseGeometry.targetFrame(
            current: current,
            targetHeight: 440
        )
        XCTAssertEqual(same, current)
    }

    // MARK: - normalisedOriginY round-trips across collapse state

    func testNormalisedOriginYExpandedIsPassthrough() {
        // When expanded, `frame.origin.y` already IS the expanded-space value.
        let frame = CGRect(x: 0, y: 500, width: 320, height: 440)
        let y = BucketCollapseGeometry.normalisedOriginY(
            frame: frame,
            isCollapsed: false,
            expandedHeight: 440
        )
        XCTAssertEqual(y, 500)
    }

    func testNormalisedOriginYCollapsedReversesThePushUp() {
        // Start expanded at origin.y=500, height=440.
        // Collapse to height=116: origin.y becomes 500 + (440-116) = 824.
        // Normalising 824 with isCollapsed=true must give back 500.
        let collapsed = CGRect(x: 0, y: 824, width: 320, height: 116)
        let y = BucketCollapseGeometry.normalisedOriginY(
            frame: collapsed,
            isCollapsed: true,
            expandedHeight: 440
        )
        XCTAssertEqual(y, 500,
                       "Collapsed y must normalise to the expanded y so restore-on-launch lands in place.")
    }

    func testNormalisedOriginYSurvivesSizeDriftDueToMidAnimationCapture() {
        // Pathological case: expandedHeight got corrupted to 350 mid-animation
        // (the bug we just fixed). Even with a wrong expandedHeight, the math
        // stays self-consistent — we just land at a different (consistent)
        // position. Guarantees the window doesn't crawl across the screen
        // even if another regression re-introduces mid-animation capture.
        let collapsed = CGRect(x: 0, y: 734, width: 320, height: 116)
        let y = BucketCollapseGeometry.normalisedOriginY(
            frame: collapsed,
            isCollapsed: true,
            expandedHeight: 350
        )
        XCTAssertEqual(y, 500)
    }

    // MARK: - isEssentiallyCollapsed buffer

    func testIsEssentiallyCollapsedCatchesSentinelHeight() {
        XCTAssertTrue(BucketCollapseGeometry.isEssentiallyCollapsed(
            height: 116, collapsedSentinel: 116
        ))
    }

    func testIsEssentiallyCollapsedCatchesMidAnimationValues() {
        // Halfway through an expand animation (t=0.5), the frame is around
        // 278. A bogus persist here must be rejected.
        XCTAssertTrue(BucketCollapseGeometry.isEssentiallyCollapsed(
            height: 140, collapsedSentinel: 116
        ))
        XCTAssertTrue(BucketCollapseGeometry.isEssentiallyCollapsed(
            height: 155, collapsedSentinel: 116
        ))
    }

    func testIsEssentiallyCollapsedPassesUserSizes() {
        // 240 is the minimum user-resized height; 440 is the default.
        // Both must count as clearly-expanded so `windowDidEndLiveResize`
        // actually persists them.
        XCTAssertFalse(BucketCollapseGeometry.isEssentiallyCollapsed(
            height: 240, collapsedSentinel: 116
        ))
        XCTAssertFalse(BucketCollapseGeometry.isEssentiallyCollapsed(
            height: 440, collapsedSentinel: 116
        ))
        XCTAssertFalse(BucketCollapseGeometry.isEssentiallyCollapsed(
            height: 1200, collapsedSentinel: 116
        ))
    }

    // MARK: - Full cycle smoke test

    func testRapidFocusFlipDoesNotDriftPosition() {
        // Simulates the exact user scenario: expand → collapse → expand
        // → collapse → expand. Top edge and width must stay pinned
        // across the whole sequence.
        var frame = CGRect(x: 200, y: 300, width: 320, height: 440)
        let originalTop = frame.origin.y + frame.height

        for _ in 0..<5 {
            // Collapse
            frame = BucketCollapseGeometry.targetFrame(current: frame, targetHeight: 116)
            XCTAssertEqual(frame.origin.y + frame.height, originalTop)
            XCTAssertEqual(frame.size.width, 320)
            // Expand
            frame = BucketCollapseGeometry.targetFrame(current: frame, targetHeight: 440)
            XCTAssertEqual(frame.origin.y + frame.height, originalTop)
            XCTAssertEqual(frame.size.width, 320)
            XCTAssertEqual(frame.size.height, 440)
        }
    }
}
