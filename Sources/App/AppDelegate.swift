import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Core Services

    let sessionManager = SessionManager()
    private var watchdog: Watchdog?
    private var httpServer: HTTPServer?
    private var gitPoller: GitStatusPoller?
    private var peerDiscovery: PeerDiscovery?
    private(set) var visitManager: VisitManager?

    // MARK: - Animation & Bubbles

    let spriteEngine = SpriteEngine()
    let bubbleManager = BubbleManager()
    private var mcpSayObserver: NSObjectProtocol?
    private var taskCompletedObserver: NSObjectProtocol?
    private var mcpReactObserver: NSObjectProtocol?
    private var mcpReactWork: DispatchWorkItem?
    private var trayObserver: NSObjectProtocol?

    // MARK: - UI

    private var statusItem: NSStatusItem?
    private var panelWindow: SnorOhPanelWindow?
    private let settingsWindow = SettingsWindow()

    // MARK: - Bucket (Epic 01)
    private var bucketWindow: BucketWindow?
    private var bucketObserver: NSObjectProtocol?

    // MARK: - Quick paste (⌘⇧V popup)
    private var quickPastePanel: QuickPastePanel?
    private var bucketSettingsObserver: NSObjectProtocol?
    private var lastBucketHotkey: HotkeyBinding?
    private var lastQuickPasteHotkey: HotkeyBinding?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon (LSUIElement=true in Info.plist, but also enforce at runtime)
        if UserDefaults.standard.bool(forKey: "hideDock") {
            NSApp.setActivationPolicy(.accessory)
        }

        CustomOhhManager.shared.load()
        BucketManager.shared.load()
        loadSavedPreferences()
        runSetup()
        startHTTPServer()
        // Populate the session list from pidfiles on disk BEFORE the watchdog
        // starts — otherwise the first tick would wipe anything that hadn't
        // checked in yet, defeating the whole re-discovery guarantee.
        sessionManager.loadExistingSessions()
        startWatchdog()
        startGitPoller()
        if UserDefaults.standard.object(forKey: DefaultsKey.peerDiscoveryEnabled) as? Bool ?? true {
            startPeerDiscovery()
        }
        setupMenuBar()
        createPanel()
        startBubbleObserving()
        startBucketFeature()

        // Transition from initializing → searching after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if self.sessionManager.currentUI == .initializing {
                self.sessionManager.handleHeartbeat(pid: 9999, cwd: nil)
                // Remove the fake session so it goes to searching/disconnected
                self.sessionManager.removeSession(pid: 9999)
            }
        }

        // Welcome bubble after brief delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            self.bubbleManager.showWelcome()

            // First-launch bucket tip — fires once, then never again.
            let tipKey = DefaultsKey.bucketTipShown
            if !UserDefaults.standard.bool(forKey: tipKey) {
                UserDefaults.standard.set(true, forKey: tipKey)
                DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                    self.bubbleManager.show("Drop anything onto me to bucket it!", durationMs: 6000)
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        spriteEngine.stop()
        mcpReactWork?.cancel()
        for observer in [mcpSayObserver, taskCompletedObserver, mcpReactObserver, trayObserver, bucketObserver, bucketSettingsObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
        }
        if let obs = statusBarObserver { NotificationCenter.default.removeObserver(obs) }
        ClipboardMonitor.shared.stop()
        HotkeyRegistrar.shared.unregister()
        HotkeyRegistrar.shared.unregisterBucketSwitchers()

        // Flush any pending debounced bucket write synchronously (bounded wait)
        // so a quit mid-debounce doesn't lose the latest mutation.
        let sema = DispatchSemaphore(value: 0)
        Task { @MainActor in
            await BucketManager.shared.flushPendingWrites()
            sema.signal()
        }
        _ = sema.wait(timeout: .now() + .milliseconds(500))

        peerDiscovery?.stop()
        watchdog?.stop()
        httpServer?.stop()
        gitPoller?.stop()
    }

    // MARK: - Bucket Feature (Epic 01)

    private func startBucketFeature() {
        // Start clipboard monitor (respects BucketSettings.captureClipboard)
        ClipboardMonitor.shared.start()

        // Standalone bucket window — hidden until the hotkey shows it.
        bucketWindow = BucketWindow(manager: BucketManager.shared)

        // Global hotkey toggles *only* the bucket window. The main snor-oh
        // panel (mascot + sessions) is unaffected.
        registerBucketHotkeys()
        // Re-register on settings change so the recorder UI takes effect live.
        bucketSettingsObserver = NotificationCenter.default.addObserver(
            forName: .bucketChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.registerBucketHotkeys()
        }

        // Phase 6: ⌃⌥1…⌃⌥9 switches the active bucket to the Nth visible one.
        // Handler reads `activeBuckets` live, so no re-register on CRUD.
        HotkeyRegistrar.shared.registerBucketSwitchers { n in
            Task { @MainActor in
                let manager = BucketManager.shared
                guard let target = BucketManager.resolveBucketSwitcherTarget(
                    n: n, activeBuckets: manager.activeBuckets
                ) else { return }
                manager.setActiveBucket(id: target)
            }
        }

        // Status bar reflects bucket count too
        bucketObserver = NotificationCenter.default.addObserver(
            forName: .bucketChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.updateStatusBarText()
        }
    }

    @objc func showBucket() {
        bucketWindow?.makeKeyAndOrderFront(nil)
    }

    /// Registers (or re-registers) the bucket-toggle and quick-paste hotkeys
    /// from current settings. Idempotent; the Carbon registrar unregisters
    /// its prior ref before each call. Diffs against `last*Hotkey` so a
    /// `.bucketChanged` notification that didn't actually change the binding
    /// doesn't churn Carbon registrations.
    private func registerBucketHotkeys() {
        let settings = BucketManager.shared.settings

        if settings.hotkey != lastBucketHotkey {
            HotkeyRegistrar.shared.registerBucketToggle(binding: settings.hotkey) { [weak self] in
                self?.bucketWindow?.toggle()
            }
            lastBucketHotkey = settings.hotkey
        }

        if settings.quickPasteHotkey != lastQuickPasteHotkey {
            HotkeyRegistrar.shared.registerQuickPaste(binding: settings.quickPasteHotkey) { [weak self] in
                self?.showQuickPaste()
            }
            lastQuickPasteHotkey = settings.quickPasteHotkey
        }
    }

    /// Opens the ⌘⇧V quick-paste popup with the N newest items across all
    /// active buckets. Pattern (Raycast/Alfred-style):
    ///   1. Record the currently frontmost app — the paste target.
    ///   2. Activate snor-oh briefly so the panel becomes key and keyboard
    ///      events route through our local NSEvent monitor.
    ///   3. On pick: copy to pasteboard → re-activate the recorded app →
    ///      synth ⌘V (gracefully degrades if Accessibility isn't granted).
    @MainActor
    private func showQuickPaste() {
        let manager = BucketManager.shared
        let items = manager.latestItemsAcrossActiveBuckets(limit: manager.settings.quickPasteCount)

        // Capture the paste target BEFORE we activate ourselves.
        let targetApp = NSWorkspace.shared.frontmostApplication

        NSApp.activate(ignoringOtherApps: true)

        let panel = quickPastePanel ?? QuickPastePanel()
        quickPastePanel = panel

        let sidecarRoot = manager.storeRootURL
        panel.show(
            items: items,
            sidecarRoot: sidecarRoot,
            onSelect: { idx in
                guard idx >= 0, idx < items.count else { return }
                QuickPaster.copyItemToPasteboard(items[idx], sidecarRoot: sidecarRoot)
                // Hand focus back to the paste target, then synth ⌘V. The
                // activation is async on macOS so the ⌘V delay in
                // `synthesizeCommandV` (~60 ms) gives AppKit time to settle.
                targetApp?.activate(options: [])
                QuickPaster.synthesizeCommandV()
            },
            onCancel: {
                // Restore focus to where the user was.
                targetApp?.activate(options: [])
            }
        )
    }

    // MARK: - HTTP Server

    private func startHTTPServer() {
        let portStr = ProcessInfo.processInfo.environment["SNOR_OH_PORT"] ?? "1234"
        let port = Int(portStr) ?? 1234

        sessionManager.httpPort = port
        httpServer = HTTPServer(sessionManager: sessionManager, port: port)
        do {
            try httpServer?.start()
            print("[snor-oh] HTTP server started on 0.0.0.0:\(port)")
        } catch {
            print("[snor-oh] Failed to start HTTP server: \(error)")
            // Port may be in use — show alert
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Port \(port) is already in use"
                alert.informativeText = "Another instance of snor-oh may be running. Only one instance can run at a time."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Quit")
                alert.runModal()
                NSApp.terminate(nil)
            }
        }
    }

    // MARK: - Watchdog

    private func startWatchdog() {
        watchdog = Watchdog(sessionManager: sessionManager)
        watchdog?.start()
    }

    // MARK: - Menu Bar

    private var statusBarObserver: NSObjectProtocol?

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "snor-oh")
            button.image?.size = NSSize(width: 16, height: 16)
            button.imagePosition = .imageLeading
            button.action = #selector(toggleMascotWindow)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        updateStatusBarText()

        // Update status bar text when sessions change
        statusBarObserver = NotificationCenter.default.addObserver(
            forName: .statusChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.updateStatusBarText()
        }
    }

    private func updateStatusBarText() {
        guard let button = statusItem?.button else { return }
        let projects = sessionManager.projects
        let bucketCount = BucketManager.shared.activeBuckets.reduce(0) { $0 + $1.items.count }

        if projects.isEmpty && bucketCount == 0 {
            button.attributedTitle = NSAttributedString()
            return
        }

        // Count by per-project aggregate status. Two shells in the same
        // folder share one project, so the status bar shows "1 busy" not
        // "2 busy" — matches the panel's project rows as a single source
        // of truth. Sessions remain the underlying plumbing.
        var counts: [(Status, Int)] = []
        var map: [Status: Int] = [:]
        for p in projects { map[p.status, default: 0] += 1 }
        // Sort: non-idle first by priority desc, idle last
        let sorted = map.sorted { a, b in
            if a.key == .idle { return false }
            if b.key == .idle { return true }
            return a.key.priority > b.key.priority
        }
        counts = sorted.map { ($0.key, $0.value) }

        // Build attributed string: " ● 2 ● 1 ● 1   📦 3"
        let result = NSMutableAttributedString()
        let space = NSAttributedString(string: " ")

        for (status, count) in counts {
            let color = statusBarColor(status)
            result.append(space)
            // Colored dot
            let dot = NSAttributedString(
                string: "\u{25CF}",
                attributes: [
                    .foregroundColor: color,
                    .font: NSFont.systemFont(ofSize: 7, weight: .bold),
                    .baselineOffset: 1.0,
                ]
            )
            result.append(dot)
            // Count
            let countStr = NSAttributedString(
                string: "\(count)",
                attributes: [
                    .foregroundColor: NSColor.labelColor,
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
                ]
            )
            result.append(countStr)
        }

        if bucketCount > 0 {
            if !counts.isEmpty {
                result.append(NSAttributedString(string: "  "))
            } else {
                result.append(space)
            }
            let bucketDot = NSAttributedString(
                string: "\u{25CF}",
                attributes: [
                    .foregroundColor: NSColor.systemOrange,
                    .font: NSFont.systemFont(ofSize: 7, weight: .bold),
                    .baselineOffset: 1.0,
                ]
            )
            result.append(bucketDot)
            result.append(NSAttributedString(
                string: "\(bucketCount)",
                attributes: [
                    .foregroundColor: NSColor.labelColor,
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
                ]
            ))
        }

        button.attributedTitle = result
    }

    private func statusBarColor(_ status: Status) -> NSColor {
        switch status {
        case .busy:         return NSColor(red: 1.0, green: 0.42, blue: 0.42, alpha: 1)
        case .idle:         return NSColor(red: 0.3, green: 0.85, blue: 0.39, alpha: 1)
        case .service:      return NSColor(red: 0.37, green: 0.36, blue: 0.9, alpha: 1)
        case .searching, .initializing:
                            return NSColor(red: 1.0, green: 0.85, blue: 0.24, alpha: 1)
        case .disconnected: return NSColor(red: 0.39, green: 0.39, blue: 0.4, alpha: 1)
        case .visiting:     return .systemTeal
        }
    }

    @objc private func toggleMascotWindow(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp {
            showContextMenu(sender)
        } else {
            if panelWindow?.isVisible == true {
                panelWindow?.orderOut(nil)
            } else {
                panelWindow?.orderFront(nil)
            }
        }
    }

    private func showContextMenu(_ sender: NSStatusBarButton) {
        let menu = NSMenu()
        menu.addItem(withTitle: "Show", action: #selector(showPanel), keyEquivalent: "")
        let bucketItem = NSMenuItem(
            title: "Show Bucket",
            action: #selector(showBucket),
            keyEquivalent: "b"
        )
        bucketItem.keyEquivalentModifierMask = [.control, .option]
        menu.addItem(bucketItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit snor-oh", action: #selector(quitApp), keyEquivalent: "q")

        for item in menu.items {
            item.target = self
        }

        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil  // Reset so left-click works again
    }

    @objc private func showPanel() {
        panelWindow?.orderFront(nil)
    }

    @objc private func openSettings() {
        settingsWindow.show(sessionManager: sessionManager, spriteEngine: spriteEngine)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: - Preferences

    private func loadSavedPreferences() {
        let defaults = UserDefaults.standard
        if let pet = defaults.string(forKey: DefaultsKey.pet), !pet.isEmpty {
            sessionManager.pet = pet
        }
        if let nickname = defaults.string(forKey: DefaultsKey.nickname), !nickname.isEmpty {
            sessionManager.nickname = nickname
        }

        // Apply saved theme
        applyTheme()

        // Observe preference changes (tray visibility, theme)
        trayObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let visible = UserDefaults.standard.object(forKey: DefaultsKey.trayVisible) as? Bool ?? true
            self.statusItem?.isVisible = visible
            self.applyTheme()

            // Toggle peer discovery on/off
            let peerEnabled = UserDefaults.standard.object(forKey: DefaultsKey.peerDiscoveryEnabled) as? Bool ?? true
            if peerEnabled && self.peerDiscovery == nil {
                self.startPeerDiscovery()
            } else if !peerEnabled && self.peerDiscovery != nil {
                self.peerDiscovery?.stop()
                self.peerDiscovery = nil
                self.visitManager = nil
                self.sessionManager.clearAllPeers()
            }
        }
    }

    /// Apply theme setting to app appearance.
    private func applyTheme() {
        let theme = UserDefaults.standard.string(forKey: DefaultsKey.theme) ?? "dark"
        switch theme {
        case "dark":
            NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light":
            NSApp.appearance = NSAppearance(named: .aqua)
        default:
            NSApp.appearance = nil  // Follow system
        }
    }

    // MARK: - Setup

    private var setupWizardWindow: NSWindow?

    private func runSetup() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let marker = home.appendingPathComponent(".snor-oh/setup-done")

        if !FileManager.default.fileExists(atPath: marker.path) {
            // First launch: show setup wizard (it handles MCP install + hooks)
            showSetupWizard()
        } else {
            // Subsequent launches: update MCP server + shell hooks + migrate Claude hooks
            DispatchQueue.global(qos: .utility).async {
                MCPInstaller.installServer()
                MCPInstaller.installShellHooks()
                ClaudeHooks.migrate()
            }
        }
    }

    private func showSetupWizard() {
        let wizard = SetupWizard { [weak self] in
            self?.setupWizardWindow?.close()
            self?.setupWizardWindow = nil
        }

        let hostingView = NSHostingView(rootView: wizard)
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "snor-oh Setup"
        win.contentView = hostingView
        win.center()
        win.isReleasedWhenClosed = false
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        setupWizardWindow = win
    }

    // MARK: - Git Poller

    private func startGitPoller() {
        gitPoller = GitStatusPoller(sessionManager: sessionManager)
        gitPoller?.start()
    }

    // MARK: - Peer Discovery

    private func startPeerDiscovery() {
        let discovery = PeerDiscovery(sessionManager: sessionManager)
        peerDiscovery = discovery
        visitManager = VisitManager(sessionManager: sessionManager, discovery: discovery)
        discovery.start()
    }

    // MARK: - Panel

    private func createPanel() {
        panelWindow = SnorOhPanelWindow(
            sessionManager: sessionManager,
            spriteEngine: spriteEngine,
            bubbleManager: bubbleManager,
            visitManager: visitManager
        )
        panelWindow?.orderFront(nil)
    }

    // MARK: - Menu Bar Popover

    private var menuBarPopover: NSPopover?
    private var popoverDismissWork: DispatchWorkItem?

    /// Show a temporary speech bubble popover from the menu bar icon.
    private func showMenuBarBubble(_ message: String, durationSecs: Double = 4.0) {
        guard let button = statusItem?.button else { return }

        popoverDismissWork?.cancel()
        menuBarPopover?.performClose(nil)

        let popover = NSPopover()
        menuBarPopover = popover

        let view = Text(message)
            .font(.system(size: 12, weight: .medium))
            .multilineTextAlignment(.center)
            .lineLimit(5)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 230)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

        popover.contentViewController = NSHostingController(rootView: view)
        popover.behavior = .applicationDefined
        popover.animates = true

        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

        let work = DispatchWorkItem { [weak self] in
            self?.menuBarPopover?.performClose(nil)
        }
        popoverDismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + durationSecs, execute: work)
    }

    // MARK: - Bubble Triggers

    /// Listen for MCP say events, task completions, and reactions.
    private func startBubbleObserving() {
        // MCP say → speech bubble (panel + menu bar if panel hidden)
        mcpSayObserver = NotificationCenter.default.addObserver(
            forName: .mcpSay,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let message = notification.userInfo?["message"] as? String else { return }
            let durationMs = notification.userInfo?["duration_ms"] as? UInt64 ?? 7000
            self.bubbleManager.show(message, durationMs: durationMs)
            if self.panelWindow?.isVisible != true {
                self.showMenuBarBubble(message, durationSecs: Double(durationMs) / 1000.0)
            }
        }

        // Task completed → random completion bubble (panel + menu bar if panel hidden)
        taskCompletedObserver = NotificationCenter.default.addObserver(
            forName: .taskCompleted,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.bubbleManager.showTaskCompleted()
            if self?.panelWindow?.isVisible != true {
                if let msg = BubbleManager.taskCompletedMessages.randomElement() {
                    self?.showMenuBarBubble(msg)
                }
            }
        }

        // MCP react → temporary sprite status override
        mcpReactObserver = NotificationCenter.default.addObserver(
            forName: .mcpReact,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let statusStr = notification.userInfo?["status"] as? String,
                  let status = Status(rawValue: statusStr) else { return }
            let durationMs = notification.userInfo?["duration_ms"] as? UInt64 ?? 3000

            // Cancel any pending restore from a previous reaction
            self.mcpReactWork?.cancel()

            // Temporarily override sprite to reaction status
            self.spriteEngine.setStatus(status)

            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.spriteEngine.setStatus(self.sessionManager.currentUI)
            }
            self.mcpReactWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(durationMs) / 1000.0, execute: work)
        }
    }
}
