import Foundation
import CoreGraphics

/// Pure geometry helpers for `BucketWindow`'s auto-collapse animation.
///
/// Extracted to module scope so they can be unit-tested without spinning up
/// an actual NSWindow (which in turn needs a main run loop and an NSApp).
/// The invariants these helpers enforce are the cause of every "window in
/// the wrong place after collapse" bug that existed in the inline version:
///
///   - The window's **visual top edge stays anchored** through the collapse
///     and expand animation. We push origin.y by the height delta because
///     Cocoa's bottom-left origin convention means a naive shrink pulls the
///     top edge down with the bottom.
///   - Persisted `origin.y` is always stored in the "expanded" coordinate
///     space so restore-on-launch lands at the same visual spot regardless
///     of what collapsed state the window last quit in.
enum BucketCollapseGeometry {

    /// Target frame for a collapse/expand transition that keeps the
    /// window's visual top edge pinned.
    ///
    /// `current` is the live frame. `targetHeight` is either the collapsed
    /// sentinel (~116) or the user's preferred expanded height (≥240).
    /// Returns the frame you should pass into `NSWindow.setFrame(_:display:animate:)`.
    static func targetFrame(current: CGRect, targetHeight: CGFloat) -> CGRect {
        var new = current
        new.origin.y += (current.height - targetHeight)
        new.size.height = targetHeight
        return new
    }

    /// Normalises `frame.origin.y` to the expanded coordinate space —
    /// i.e. where the bottom-left would be if the window were at
    /// `expandedHeight`. Used on every persist so the next launch opens at
    /// the correct position regardless of current collapse state.
    static func normalisedOriginY(
        frame: CGRect,
        isCollapsed: Bool,
        expandedHeight: CGFloat
    ) -> CGFloat {
        guard isCollapsed else { return frame.origin.y }
        // When collapsed, origin.y was pushed UP by (expandedHeight − frame.height).
        // Reverse it so the stored Y is what origin.y would be while expanded.
        return frame.origin.y - (expandedHeight - frame.height)
    }

    /// Returns `true` when `height` is close enough to the collapsed
    /// sentinel that reading it as "the user's preferred expanded height"
    /// would be a bug. Used to gate persistence: never save a collapsed
    /// size as the expanded one.
    ///
    /// The 40 pt buffer covers mid-animation transient values so a stray
    /// `mouseUp` during an expand animation doesn't persist the wrong value.
    static func isEssentiallyCollapsed(
        height: CGFloat,
        collapsedSentinel: CGFloat
    ) -> Bool {
        height < collapsedSentinel + 40
    }
}
