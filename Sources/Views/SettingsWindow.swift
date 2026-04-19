import AppKit
import SwiftUI

/// Standard macOS settings window. Singleton — only one instance is shown at a time.
final class SettingsWindow: NSObject, NSWindowDelegate {

    private var window: NSWindow?

    func show(sessionManager: SessionManager, spriteEngine: SpriteEngine) {
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Close any previous (invisible) window before creating a new one
        window?.close()
        window = nil

        let settingsView = SettingsView(
            sessionManager: sessionManager,
            spriteEngine: spriteEngine
        )

        let hostingView = NSHostingView(rootView: settingsView)
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "snor-oh Settings"
        win.contentView = hostingView
        win.minSize = NSSize(width: 640, height: 440)
        win.center()
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = win
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // Release the window and all SwiftUI hosting views (including PetCard engines)
        window = nil
    }
}
