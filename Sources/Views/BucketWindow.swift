import AppKit
import SwiftUI

/// Standalone floating window that hosts the Bucket.
///
/// Lifecycle:
///   - Created once in `AppDelegate.startBucketFeature()`, hidden by default.
///   - Toggled by the ⌃⌥B global hotkey.
///   - Also available from the status-bar right-click menu ("Show Bucket").
///   - Does NOT interfere with the main snor-oh panel window.
final class BucketWindow: NSPanel, NSWindowDelegate {

    private let manager: BucketManager
    private var savePositionTimer: Timer?

    /// Epic 07 follow-up — true while the bucket is auto-collapsed (window
    /// lost key / focus). The SwiftUI content watches
    /// `.bucketWindowCollapseChanged` to hide its list.
    private(set) var isCollapsed: Bool = false

    /// Height the window *should* return to on expand. Updated **only** in
    /// `windowDidEndLiveResize` (the canonical "user finished dragging the
    /// resize handle" NSWindowDelegate hook). We deliberately never read
    /// `frame.height` elsewhere to derive this value, because the frame is
    /// in-flight during the AppKit collapse/expand animation and any such
    /// capture produces a wrong "preferred" size — the root cause of every
    /// "bucket doesn't expand to original size" bug in the first cut.
    private var expandedHeight: CGFloat

    /// Fixed height the window shrinks to when collapsed — enough for
    /// header + tab strip + search toolbar with no list visible.
    private let collapsedHeight: CGFloat = 116

    /// Screen-coordinate pointer location captured on every leftMouseDown
    /// that routed through this window's `sendEvent(_:)`. Compared against
    /// the pointer's screen location at mouseUp time to decide click vs
    /// drag — *pointer* movement, not *window* movement, because
    /// `performDrag` can swallow both the events and any window-frame
    /// change when a drag barely crosses its own internal threshold. If
    /// the pointer moved more than a small threshold during the hold, we
    /// treat it as drag intent regardless of whether the window visibly
    /// moved, and suppress the auto-expand.
    private var mouseDownLocationOnScreen: CGPoint?

    /// True while a leftMouseDown has been seen but the matching leftMouseUp
    /// hasn't yet. `becomeKey` checks this to defer its auto-expand until
    /// `sendEvent` sees the mouseUp and decides.
    private var clickInProgress: Bool = false

    /// Pointer can wander a couple of pixels during a steady click without
    /// it being a drag attempt. Above this threshold we treat the gesture
    /// as a drag and leave the window collapsed.
    private let clickVsDragPixelThreshold: CGFloat = 3

    init(manager: BucketManager) {
        self.manager = manager

        let defaults = UserDefaults.standard
        let savedWidth = defaults.object(forKey: DefaultsKey.bucketWindowWidth) as? CGFloat ?? 320
        // Prefer the dedicated expanded-height key, then fall back to the
        // generic window-height key. Reject values that are essentially
        // collapsed — those come from the v0.8.0 bug that persisted a
        // mid-animation height as the "preferred" size, causing subsequent
        // expansions to a wrong target. `isEssentiallyCollapsed` uses the
        // same 40-pt buffer the runtime guard uses.
        let savedExpanded = defaults.object(forKey: DefaultsKey.bucketExpandedHeight) as? CGFloat
        let savedHeight = defaults.object(forKey: DefaultsKey.bucketWindowHeight) as? CGFloat
        let candidate = savedExpanded ?? savedHeight ?? 440
        if BucketCollapseGeometry.isEssentiallyCollapsed(
            height: candidate, collapsedSentinel: 116
        ) {
            Log.bucketCollapse.warning(
                "discarding corrupted saved expandedHeight=\(candidate, privacy: .public); falling back to 440"
            )
            self.expandedHeight = 440
        } else {
            self.expandedHeight = max(240, candidate)
        }
        let size = NSSize(
            width: max(280, savedWidth),
            height: self.expandedHeight
        )

        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        // Only the header acts as a drag handle — see WindowDragArea below.
        // Dragging on a card must NOT move the window, otherwise SwiftUI's
        // `.onDrag` never wins and items can't leave the bucket.
        isMovableByWindowBackground = false
        hidesOnDeactivate = false

        // Min resize — keep the search field + a couple cards legible.
        minSize = NSSize(width: 280, height: 240)

        // NSWindowDelegate conformance: we use it specifically for
        // `windowDidEndLiveResize`. All other delegate methods default to
        // pass-through, which is what we want for a plain panel.
        self.delegate = self

        let content = BucketWindowContent(
            manager: manager,
            onClose: { [weak self] in self?.orderOut(nil) },
            applyWindowAlpha: { [weak self] alpha in
                self?.alphaValue = CGFloat(alpha)
            }
        )
        // NSHostingView installation requires care to avoid two separate
        // regressions that bit us during Epic 07:
        //
        //   1. If NSHostingView *is* the window's `contentView` directly,
        //      its default `sizingOptions` (macOS 13+) feeds SwiftUI's
        //      preferred-content-size back to the window every layout
        //      pass. Our `setFrame(..., 116)` animation reverts to 103
        //      within one runloop tick because SwiftUI's collapsed
        //      content is 103 tall.
        //
        //   2. Setting `sizingOptions = []` stops the feedback loop, but
        //      then the hosting view has no autoresizing mask and no
        //      Auto Layout constraints — the next Auto Layout pass
        //      (triggered mid-animation by `updateAnimatedWindowSize`)
        //      finds an unresolved view and throws an uncaught ObjC
        //      exception from `_postWindowNeedsUpdateConstraints`,
        //      aborting the app when you collapse on an empty bucket.
        //
        // The fix: install a plain NSView as `contentView`, pin the
        // hosting view to its edges with explicit constraints, and set
        // `sizingOptions = []` on the hosting view. The container view
        // has `autoresizingMask = [.width, .height]` which AppKit
        // honours the moment the window frame changes. Constraints
        // satisfy the solver; sizingOptions silences the feedback loop.
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.autoresizingMask = [.width, .height]
        container.wantsLayer = true

        let host = NSHostingView(rootView: content)
        host.translatesAutoresizingMaskIntoConstraints = false
        if #available(macOS 13.0, *) {
            host.sizingOptions = []
        }
        container.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            host.topAnchor.constraint(equalTo: container.topAnchor),
            host.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        contentView = container

        // Seed alphaValue from the persisted setting before first display so
        // the bucket never flashes at 100% on open. `applyWindowAlpha` also
        // fires from `.onAppear` inside the hosting view, but that runs a
        // frame later — setting it here avoids the pop.
        self.alphaValue = CGFloat(manager.settings.backgroundOpacity)

        restorePosition()
    }

    /// Every event routed to this window passes through here before
    /// AppKit's default dispatch. We use it to distinguish a "click" from
    /// a "click-and-drag":
    ///
    ///   - On leftMouseDown: record the pointer's *screen* location and
    ///     flag a click in progress. `becomeKey` reads the flag and
    ///     defers its auto-expand so the user can start dragging without
    ///     the expand animation racing `performDrag`.
    ///   - On leftMouseUp: compare the pointer's screen location. If it
    ///     moved more than a few pixels, treat it as drag intent and
    ///     leave the window collapsed — even if `performDrag` failed to
    ///     actually move the window, the user's intent was clearly a
    ///     drag. Otherwise it was a tap: expand.
    ///
    /// `super.sendEvent(event)` still runs so the normal dispatch (drag
    /// handler, tap gestures on SwiftUI content) works unchanged.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown {
            clickInProgress = true
            mouseDownLocationOnScreen = NSEvent.mouseLocation
            Log.bucketCollapse.debug(
                "sendEvent mouseDown at screen=\(String(describing: NSEvent.mouseLocation), privacy: .public)"
            )
        }
        super.sendEvent(event)
        if event.type == .leftMouseUp {
            let upLocation = NSEvent.mouseLocation
            let dragDistance = mouseDownLocationOnScreen.map { down in
                hypot(upLocation.x - down.x, upLocation.y - down.y)
            } ?? 0
            let didDrag = dragDistance > clickVsDragPixelThreshold
            let wasInProgress = clickInProgress
            clickInProgress = false
            mouseDownLocationOnScreen = nil
            Log.bucketCollapse.debug(
                "sendEvent mouseUp: wasInProgress=\(wasInProgress, privacy: .public) dragDistance=\(dragDistance, privacy: .public) didDrag=\(didDrag, privacy: .public)"
            )
            guard wasInProgress, !didDrag,
                  isVisible, isCollapsed, isKeyWindow
            else { return }
            // Dispatch async so `performDrag` (if it was running) fully
            // returns before we start a frame animation.
            DispatchQueue.main.async { [weak self] in
                self?.applyCollapseState(false, animate: true)
            }
        }
    }

    /// NSPanel suppresses keyboard focus by default — override so the search
    /// field inside BucketView becomes first responder on cmd-F or click.
    override var canBecomeKey: Bool { true }

    func toggle() {
        if isVisible {
            orderOut(nil)
        } else {
            // If we were left collapsed last time (e.g. user hid via close
            // button while focus was elsewhere), restore expanded geometry
            // silently BEFORE showing so the window appears at full size.
            if isCollapsed {
                applyCollapseState(false, animate: false)
            }
            makeKeyAndOrderFront(nil)
        }
    }

    // MARK: - Auto-collapse on focus change (Epic 07 follow-up)

    /// When the bucket gains focus (user clicked in / hotkey'd it / started
    /// typing in search), expand to the user's preferred height.
    ///
    /// Guarded on `isVisible` because `becomeKey` can fire as part of an
    /// initial show sequence where we've already force-expanded via toggle,
    /// or during window-ordering races that we don't want to animate into.
    override func becomeKey() {
        super.becomeKey()
        Log.bucketCollapse.info(
            "becomeKey fired: isVisible=\(self.isVisible, privacy: .public) isCollapsed=\(self.isCollapsed, privacy: .public) expandedHeight=\(self.expandedHeight, privacy: .public) frame=\(String(describing: self.frame), privacy: .public) clickInProgress=\(self.clickInProgress, privacy: .public)"
        )
        guard isVisible else { return }
        // Defer expand while a click is in progress — the user may be about
        // to drag the window by the header. `sendEvent`'s leftMouseUp path
        // decides whether to expand once the click completes, based on
        // whether the window's origin moved during the click.
        if clickInProgress {
            Log.bucketCollapse.debug("becomeKey deferred — click in progress, waiting for mouseUp")
            return
        }
        applyCollapseState(false, animate: true)
    }

    /// When focus moves to any other window (another app, the mascot panel,
    /// or simply clicking on the desktop), hide the item list so the bucket
    /// becomes a minimal bar showing only header + tab strip + search.
    /// Items stay in memory — this is presentation-only.
    ///
    /// Guarded on `isVisible` so we don't run a collapse animation on a
    /// window that's being hidden — that showed up as a "flash" in v0.8.0.
    override func resignKey() {
        super.resignKey()
        Log.bucketCollapse.info(
            "resignKey fired: isVisible=\(self.isVisible, privacy: .public) isCollapsed=\(self.isCollapsed, privacy: .public) expandedHeight=\(self.expandedHeight, privacy: .public) frame=\(String(describing: self.frame), privacy: .public)"
        )
        guard isVisible else { return }
        applyCollapseState(true, animate: true)
    }

    /// Core state transition. Idempotent — repeated calls with the same
    /// value are no-ops.
    ///
    /// Critically: this function does **not** read `frame.height` to update
    /// `expandedHeight`. The expanded height is only mutated by
    /// `windowDidEndLiveResize` (on an explicit user resize end) and by
    /// `init` (from UserDefaults). Mid-animation frame reads are unsafe
    /// and caused the v0.8.0 "doesn't restore to original size" regression.
    private func applyCollapseState(_ newValue: Bool, animate: Bool) {
        guard isCollapsed != newValue else {
            Log.bucketCollapse.debug(
                "applyCollapseState no-op (already \(newValue, privacy: .public))"
            )
            return
        }
        isCollapsed = newValue

        let targetHeight = newValue ? collapsedHeight : expandedHeight

        // Relax minSize BEFORE resizing — otherwise AppKit clamps us at the
        // old minSize and we never reach the collapsed height.
        minSize = NSSize(
            width: 280,
            height: newValue ? collapsedHeight : 240
        )

        let newFrame = BucketCollapseGeometry.targetFrame(
            current: frame,
            targetHeight: targetHeight
        )
        Log.bucketCollapse.info(
            "applyCollapseState newValue=\(newValue, privacy: .public) target=\(String(describing: newFrame), privacy: .public) animate=\(animate, privacy: .public)"
        )
        // `setFrame(_:display:animate:true)` animates origin.y and size.height
        // as separate properties, and on macOS 26 those can desync by a few
        // milliseconds — visible as the window's top edge "jumping up" at the
        // start of a collapse and snapping back as height catches up.
        // Wrapping the animator() call in a single NSAnimationContext group
        // forces both properties into the same CA transaction so they move
        // in lockstep and the top edge stays pinned throughout.
        if animate {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                self.animator().setFrame(newFrame, display: true)
            }
        } else {
            setFrame(newFrame, display: true, animate: false)
        }

        NotificationCenter.default.post(
            name: .bucketWindowCollapseChanged,
            object: self,
            userInfo: ["isCollapsed": newValue]
        )
    }

    // MARK: - NSWindowDelegate

    /// Canonical signal that the user just finished dragging the resize
    /// handle. Fires once per drag, after `isInLiveResize` becomes false.
    /// This is the ONLY place we mutate `expandedHeight` from the live
    /// frame — every other code path could be racing an animation.
    func windowDidEndLiveResize(_ notification: Notification) {
        guard !isCollapsed else { return }
        guard !BucketCollapseGeometry.isEssentiallyCollapsed(
            height: frame.height,
            collapsedSentinel: collapsedHeight
        ) else { return }
        expandedHeight = frame.height
        UserDefaults.standard.set(frame.height, forKey: DefaultsKey.bucketExpandedHeight)
        savePositionAndSize()
    }

    // MARK: - Position + size persistence

    private func restorePosition() {
        let defaults = UserDefaults.standard
        if let x = defaults.object(forKey: DefaultsKey.bucketWindowX) as? CGFloat,
           let y = defaults.object(forKey: DefaultsKey.bucketWindowY) as? CGFloat {
            let savedPoint = NSPoint(x: x, y: y)
            let screen = NSScreen.screens.first(where: { $0.frame.contains(savedPoint) })
                          ?? NSScreen.main
            if let sf = screen?.visibleFrame {
                let clamped = NSPoint(
                    x: min(max(x, sf.minX), sf.maxX - frame.width),
                    y: min(max(y, sf.minY), sf.maxY - frame.height)
                )
                setFrameOrigin(clamped)
                return
            }
            setFrameOrigin(savedPoint)
        } else if let screen = NSScreen.main {
            // Default: centered right edge.
            let sf = screen.visibleFrame
            setFrameOrigin(NSPoint(
                x: sf.maxX - frame.width - 40,
                y: sf.midY - frame.height / 2
            ))
        }
    }

    /// Persists position + the **expanded** size. Never persists mid-animation
    /// or collapsed dimensions — consults `BucketCollapseGeometry` helpers so
    /// the math is identical to the unit tests.
    ///
    /// Called from `mouseUp` (position change via header drag) and from
    /// `windowDidEndLiveResize` (size change via user resize drag). Never
    /// called from inside `applyCollapseState`.
    private func savePositionAndSize() {
        let defaults = UserDefaults.standard
        defaults.set(frame.origin.x, forKey: DefaultsKey.bucketWindowX)
        let persistY = BucketCollapseGeometry.normalisedOriginY(
            frame: frame,
            isCollapsed: isCollapsed,
            expandedHeight: expandedHeight
        )
        defaults.set(persistY, forKey: DefaultsKey.bucketWindowY)
        defaults.set(frame.size.width, forKey: DefaultsKey.bucketWindowWidth)
        defaults.set(expandedHeight, forKey: DefaultsKey.bucketWindowHeight)
        defaults.set(expandedHeight, forKey: DefaultsKey.bucketExpandedHeight)
    }

    override func mouseDragged(with event: NSEvent) {
        super.mouseDragged(with: event)
        debounceSave()
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        savePositionTimer?.invalidate()
        savePositionTimer = nil
        savePositionAndSize()
    }

    private func debounceSave() {
        savePositionTimer?.invalidate()
        let t = Timer(timeInterval: 0.3, repeats: false) { [weak self] _ in
            self?.savePositionAndSize()
        }
        RunLoop.main.add(t, forMode: .common)
        savePositionTimer = t
    }
}

// MARK: - Notifications

extension Notification.Name {
    /// Posted by `BucketWindow` whenever its auto-collapse state flips.
    /// `userInfo["isCollapsed"]` is `Bool`. `BucketWindowContent` listens
    /// so it can hide the item list in lockstep with the window animation.
    static let bucketWindowCollapseChanged = Notification.Name("bucketWindowCollapseChanged")
}

// MARK: - SwiftUI content

/// Chrome + BucketView for the standalone window. Glass-card background
/// matches the session panel aesthetic.
private struct BucketWindowContent: View {
    let manager: BucketManager
    let onClose: () -> Void
    /// Called on appear and whenever `backgroundOpacity` changes. The host
    /// `BucketWindow` forwards this to `NSPanel.alphaValue` so the whole
    /// window (including VisualEffect) becomes see-through at low values.
    let applyWindowAlpha: (Double) -> Void

    @AppStorage(DefaultsKey.theme) private var theme = "dark"
    @Environment(\.colorScheme) private var colorScheme
    /// Epic 07 follow-up — mirrors `BucketWindow.isCollapsed`. Updated via
    /// `.bucketWindowCollapseChanged` so the SwiftUI layer hides the item
    /// list in lockstep with the NSWindow animating to collapsed height.
    @State private var isCollapsed: Bool = false

    private var isDark: Bool {
        switch theme {
        case "light": return false
        case "dark":  return true
        default:      return colorScheme == .dark
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()
                .opacity(isDark ? 0.15 : 0.2)

            BucketTabsView(manager: manager)

            Divider()
                .opacity(isDark ? 0.12 : 0.15)

            BucketView(
                manager: manager,
                storeRootURL: manager.storeRootURL,
                fillAvailable: true,
                hideContent: isCollapsed
            )
        }
        // Force the VStack to fill the hosting view in both axes, even
        // when `hideContent` is true. Without this the SwiftUI intrinsic
        // content size (~103 pt collapsed) becomes the hosting view's
        // "preferred" size — combined with NSHostingView's default
        // `sizingOptions`, that would shrink the NSWindow out from under
        // our `setFrame` animation. `alignment: .top` keeps the visible
        // content anchored to the top, which is how a disclosure panel
        // should feel.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            VisualEffectBackground(
                material: isDark ? .hudWindow : .sidebar,
                blendingMode: .behindWindow
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    isDark ? Color.white.opacity(0.1) : Color.black.opacity(0.1),
                    lineWidth: 0.5
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onAppear { applyWindowAlpha(manager.settings.backgroundOpacity) }
        .onChange(of: manager.settings.backgroundOpacity) { _, new in
            applyWindowAlpha(new)
        }
        // Auto-collapse follows NSWindow key state — see
        // BucketWindow.setCollapsed. We deliberately do NOT wrap this in
        // `withAnimation`: AppKit already animates the window's frame,
        // and a concurrent SwiftUI layout animation on the same hierarchy
        // produces a visible "jump" as the content briefly re-centers
        // before the removed branch fades out. Snapping `isCollapsed`
        // makes SwiftUI re-layout once, instantly, while the window
        // animation handles all the motion.
        .onReceive(NotificationCenter.default.publisher(for: .bucketWindowCollapseChanged)) { note in
            let newValue = note.userInfo?["isCollapsed"] as? Bool ?? false
            isCollapsed = newValue
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "tray.full")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.orange)
            Text("Bucket")
                .font(.system(size: 13, weight: .semibold))
            let count = manager.activeBucket.items.count
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close (⌃⌥B)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)   // was 10 — wider grip for dragging
        // Drag-to-move enabled in the header strip *and* the tab bar's
        // empty space (see BucketTabsView). Subviews like the close button
        // still receive clicks normally because AppKit only promotes the
        // drag when no responder chain child consumed the event.
        .background(WindowDragArea())
    }
}

// MARK: - Window drag handle

/// Background NSView that handles `mouseDown` by calling
/// `window.performDrag(with:)` — the most reliable way to start a window
/// drag from a borderless panel, regardless of `isMovableByWindowBackground`.
///
/// Place it as `.background()` on any strip that should double as a window
/// drag grip (header + tab bar). Interactive subviews (buttons, pills,
/// textfields) claim their own clicks via SwiftUI hit-testing and don't
/// reach the NSView, so drags are started only in truly empty space.
///
/// Card areas deliberately don't have this background — `BucketCardView.onDrag`
/// needs to own mouseDown so items can be dragged out of the bucket.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { _DragAreaView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class _DragAreaView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        // Explicit perform-drag — works even when the window isn't globally
        // movable-by-background. Safe because interactive subviews claim
        // their clicks first via SwiftUI's z-order.
        window?.performDrag(with: event)
    }
}
