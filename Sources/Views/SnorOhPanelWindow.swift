import AppKit
import SwiftUI

/// Non-activating NSPanel that hosts the unified mascot + session panel.
/// Combines the mascot sprite and snor-oh-style session cards in one window.
final class SnorOhPanelWindow: NSPanel {

    private let sessionManager: SessionManager
    private var settingsObserver: NSObjectProtocol?
    private var savePositionTimer: Timer?
    private var lastKnownSizeRaw: String
    private var lastKnownScale: Double

    init(sessionManager: SessionManager, spriteEngine: SpriteEngine, bubbleManager: BubbleManager, visitManager: VisitManager?) {
        self.sessionManager = sessionManager

        let defaults = UserDefaults.standard
        let sizeRaw = defaults.string(forKey: DefaultsKey.panelSize) ?? "regular"
        self.lastKnownSizeRaw = sizeRaw
        self.lastKnownScale = defaults.object(forKey: DefaultsKey.displayScale) as? Double ?? 1.0

        let panelSize = SnorOhSize(rawValue: sizeRaw) ?? .regular
        let size = NSSize(width: panelSize.panelWidth, height: 400)
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isMovableByWindowBackground = true
        hidesOnDeactivate = false

        let panelView = SnorOhPanelView(
            sessionManager: sessionManager,
            spriteEngine: spriteEngine,
            bubbleManager: bubbleManager,
            visitManager: visitManager
        )
        let hostingView = NSHostingView(rootView: panelView)
        hostingView.sizingOptions = [.minSize, .intrinsicContentSize]
        contentView = hostingView

        // Use fitted size for accurate initial placement
        let fittedSize = hostingView.fittingSize
        setContentSize(NSSize(width: panelSize.panelWidth, height: max(fittedSize.height, 200)))

        // Migrate position from old mascot window (one-time)
        migratePositionIfNeeded()
        restorePosition()
        startObserving()
    }

    deinit {
        savePositionTimer?.invalidate()
        if let obs = settingsObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    // MARK: - Position Migration

    /// One-time migration: if panel position is unset but mascot position exists, use it.
    private func migratePositionIfNeeded() {
        let defaults = UserDefaults.standard
        let hasPanelPos = defaults.object(forKey: DefaultsKey.panelPositionX) != nil
        guard !hasPanelPos else { return }

        if let mx = defaults.object(forKey: "mascotPositionX") as? CGFloat,
           let my = defaults.object(forKey: "mascotPositionY") as? CGFloat {
            defaults.set(mx, forKey: DefaultsKey.panelPositionX)
            defaults.set(my, forKey: DefaultsKey.panelPositionY)
        }
    }

    // MARK: - Position Persistence

    private func restorePosition() {
        let defaults = UserDefaults.standard
        let x = defaults.object(forKey: DefaultsKey.panelPositionX) as? CGFloat
        let y = defaults.object(forKey: DefaultsKey.panelPositionY) as? CGFloat

        if let x, let y {
            let savedPoint = NSPoint(x: x, y: y)
            let screen = NSScreen.screens.first(where: { $0.frame.contains(savedPoint) })
                          ?? NSScreen.main
            if let sf = screen?.visibleFrame {
                let clamped = NSPoint(
                    x: min(max(x, sf.minX), sf.maxX - frame.width),
                    y: min(max(y, sf.minY), sf.maxY - frame.height)
                )
                setFrameOrigin(clamped)
            } else {
                setFrameOrigin(savedPoint)
            }
        } else {
            // Default: top-right of screen
            if let screen = NSScreen.main {
                let sf = screen.visibleFrame
                let origin = NSPoint(
                    x: sf.maxX - frame.width - 40,
                    y: sf.maxY - frame.height - 40
                )
                setFrameOrigin(origin)
            }
        }
    }

    private func savePosition() {
        let defaults = UserDefaults.standard
        defaults.set(frame.origin.x, forKey: DefaultsKey.panelPositionX)
        defaults.set(frame.origin.y, forKey: DefaultsKey.panelPositionY)
    }

    // Debounced position save on drag
    override func mouseDragged(with event: NSEvent) {
        super.mouseDragged(with: event)
        savePositionTimer?.invalidate()
        let t = Timer(timeInterval: 0.3, repeats: false) { [weak self] _ in
            self?.savePosition()
        }
        RunLoop.main.add(t, forMode: .common)
        savePositionTimer = t
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        savePositionTimer?.invalidate()
        savePositionTimer = nil
        savePosition()
    }

    // MARK: - Observing

    private func startObserving() {
        settingsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleSettingsChange()
        }
    }

    /// Only react when panelSize or displayScale actually changed.
    private func handleSettingsChange() {
        let defaults = UserDefaults.standard
        let currentSizeRaw = defaults.string(forKey: DefaultsKey.panelSize) ?? "regular"
        let currentScale = defaults.object(forKey: DefaultsKey.displayScale) as? Double ?? 1.0

        let sizeChanged = currentSizeRaw != lastKnownSizeRaw
        let scaleChanged = abs(currentScale - lastKnownScale) > 0.01

        guard sizeChanged || scaleChanged else { return }

        lastKnownSizeRaw = currentSizeRaw
        lastKnownScale = currentScale

        let panelSize = SnorOhSize(rawValue: currentSizeRaw) ?? .regular
        let targetWidth = panelSize.panelWidth

        var newFrame = frame
        let oldTopRight = NSPoint(x: newFrame.maxX, y: newFrame.maxY)

        if abs(newFrame.width - targetWidth) > 1 {
            newFrame.size.width = targetWidth
        }

        // Anchor top-right corner on resize
        newFrame.origin.x = oldTopRight.x - newFrame.width
        newFrame.origin.y = oldTopRight.y - newFrame.height

        // Re-clamp to screen bounds
        let screen = NSScreen.screens.first(where: { $0.frame.contains(oldTopRight) })
                      ?? NSScreen.main
        if let sf = screen?.visibleFrame {
            newFrame.origin.x = min(max(newFrame.origin.x, sf.minX), sf.maxX - newFrame.width)
            newFrame.origin.y = min(max(newFrame.origin.y, sf.minY), sf.maxY - newFrame.height)
        }

        setFrame(newFrame, display: true, animate: true)
    }
}
