import AppKit
import SwiftUI

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

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon (LSUIElement=true in Info.plist, but also enforce at runtime)
        if UserDefaults.standard.bool(forKey: "hideDock") {
            NSApp.setActivationPolicy(.accessory)
        }

        CustomOhhManager.shared.load()
        loadSavedPreferences()
        runSetup()
        startHTTPServer()
        startWatchdog()
        startGitPoller()
        startPeerDiscovery()
        setupMenuBar()
        createPanel()
        startBubbleObserving()

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
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        spriteEngine.stop()
        mcpReactWork?.cancel()
        for observer in [mcpSayObserver, taskCompletedObserver, mcpReactObserver, trayObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
        }
        if let obs = statusBarObserver { NotificationCenter.default.removeObserver(obs) }
        peerDiscovery?.stop()
        watchdog?.stop()
        httpServer?.stop()
        gitPoller?.stop()
    }

    // MARK: - HTTP Server

    private func startHTTPServer() {
        let portStr = ProcessInfo.processInfo.environment["SNOR_OH_PORT"] ?? "1234"
        let port = Int(portStr) ?? 1234

        sessionManager.httpPort = port
        httpServer = HTTPServer(sessionManager: sessionManager, port: port)
        do {
            try httpServer?.start()
            print("[snor-oh] HTTP server started on 127.0.0.1:\(port)")
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

        if projects.isEmpty {
            button.attributedTitle = NSAttributedString()
            return
        }

        // Count statuses
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

        // Build attributed string: " ● 2 ● 1 ● 1"
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
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
                ]
            )
            result.append(countStr)
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
            let visible = UserDefaults.standard.object(forKey: DefaultsKey.trayVisible) as? Bool ?? true
            self?.statusItem?.isVisible = visible
            self?.applyTheme()
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
            contentRect: NSRect(x: 0, y: 0, width: 450, height: 350),
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
