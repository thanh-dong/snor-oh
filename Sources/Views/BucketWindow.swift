import AppKit
import SwiftUI

/// Standalone floating window that hosts the Bucket.
///
/// Lifecycle:
///   - Created once in `AppDelegate.startBucketFeature()`, hidden by default.
///   - Toggled by the ⌃⌥B global hotkey.
///   - Also available from the status-bar right-click menu ("Show Bucket").
///   - Does NOT interfere with the main snor-oh panel window.
final class BucketWindow: NSPanel {

    private let manager: BucketManager
    private var savePositionTimer: Timer?

    init(manager: BucketManager) {
        self.manager = manager

        let defaults = UserDefaults.standard
        let savedWidth = defaults.object(forKey: DefaultsKey.bucketWindowWidth) as? CGFloat ?? 320
        let savedHeight = defaults.object(forKey: DefaultsKey.bucketWindowHeight) as? CGFloat ?? 440
        let size = NSSize(
            width: max(280, savedWidth),
            height: max(240, savedHeight)
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
        isMovableByWindowBackground = true
        hidesOnDeactivate = false

        // Min resize — keep the search field + a couple cards legible.
        minSize = NSSize(width: 280, height: 240)

        let content = BucketWindowContent(
            manager: manager,
            onClose: { [weak self] in self?.orderOut(nil) }
        )
        contentView = NSHostingView(rootView: content)

        restorePosition()
    }

    /// NSPanel suppresses keyboard focus by default — override so the search
    /// field inside BucketView becomes first responder on cmd-F or click.
    override var canBecomeKey: Bool { true }

    func toggle() {
        if isVisible {
            orderOut(nil)
        } else {
            makeKeyAndOrderFront(nil)
        }
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

    private func savePositionAndSize() {
        let defaults = UserDefaults.standard
        defaults.set(frame.origin.x, forKey: DefaultsKey.bucketWindowX)
        defaults.set(frame.origin.y, forKey: DefaultsKey.bucketWindowY)
        defaults.set(frame.size.width, forKey: DefaultsKey.bucketWindowWidth)
        defaults.set(frame.size.height, forKey: DefaultsKey.bucketWindowHeight)
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

// MARK: - SwiftUI content

/// Chrome + BucketView for the standalone window. Glass-card background
/// matches the session panel aesthetic.
private struct BucketWindowContent: View {
    let manager: BucketManager
    let onClose: () -> Void

    @AppStorage(DefaultsKey.theme) private var theme = "dark"
    @Environment(\.colorScheme) private var colorScheme

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

            BucketView(
                manager: manager,
                storeRootURL: manager.storeRootURL,
                fillAvailable: true
            )
        }
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
        .padding(.vertical, 10)
    }
}
