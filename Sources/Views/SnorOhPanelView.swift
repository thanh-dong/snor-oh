import SwiftUI
import AppKit
import Network

// MARK: - Animated "Working..." label

/// Busy-state label that pulses one of three dots at a time. Width stays
/// stable (all three dots always render — only opacity varies), so the row
/// layout doesn't jitter while the status flashes.
struct AnimatedWorkingLabel: View {
    let font: Font
    let color: Color

    @State private var activeDot: Int = 0

    var body: some View {
        HStack(spacing: 0) {
            Text("Working")
                .font(font)
                .foregroundStyle(color)
            HStack(spacing: 0) {
                ForEach(0..<3, id: \.self) { i in
                    Text(".")
                        .font(font)
                        .foregroundStyle(color.opacity(activeDot == i ? 1.0 : 0.25))
                }
            }
        }
        .onReceive(Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()) { _ in
            activeDot = (activeDot + 1) % 3
        }
    }
}

// MARK: - Panel Size

enum SnorOhSize: String, CaseIterable {
    case compact, regular, large

    var panelWidth: CGFloat {
        switch self {
        case .compact: return 240
        case .regular: return 280
        case .large:   return 320
        }
    }

    var projectFont: CGFloat {
        switch self {
        case .compact: return 11
        case .regular: return 12
        case .large:   return 13
        }
    }

    var metaFont: CGFloat {
        switch self {
        case .compact: return 9
        case .regular: return 10
        case .large:   return 11
        }
    }

    var dotSize: CGFloat {
        switch self {
        case .compact: return 5
        case .regular: return 6
        case .large:   return 7
        }
    }

    var rowHeight: CGFloat {
        switch self {
        case .compact: return 26
        case .regular: return 30
        case .large:   return 34
        }
    }

    var heroSpriteSize: CGFloat {
        switch self {
        case .compact: return 64
        case .regular: return 80
        case .large:   return 96
        }
    }
}

// MARK: - Panel View (Tamagotchi layout)

struct SnorOhPanelView: View {
    let sessionManager: SessionManager
    let spriteEngine: SpriteEngine
    let bubbleManager: BubbleManager
    let visitManager: VisitManager?
    @State private var messagePeer: PeerInfo?
    @State private var messageText = ""
    @State private var mascotDropTargeted = false

    @AppStorage(DefaultsKey.panelSize) private var sizeRaw = "regular"
    @AppStorage(DefaultsKey.sidebarCollapsed) private var collapsed = false
    @AppStorage(DefaultsKey.theme) private var theme = "dark"
    @AppStorage(DefaultsKey.displayScale) private var displayScale = 1.0
    @AppStorage(DefaultsKey.mascotVisible) private var mascotVisible = true
    @AppStorage(DefaultsKey.glowMode) private var glowMode = "off"
    @Environment(\.colorScheme) private var colorScheme

    private var size: SnorOhSize {
        SnorOhSize(rawValue: sizeRaw) ?? .regular
    }

    private var isDark: Bool {
        switch theme {
        case "light": return false
        case "dark": return true
        default: return colorScheme == .dark
        }
    }

    private var awayDigest: AwayDigestCollector? {
        (NSApp.delegate as? AppDelegate)?.awayDigestCollector
    }

    private var spriteSize: CGFloat {
        size.heroSpriteSize * displayScale
    }

    private var glowColor: Color {
        switch glowMode {
        case "light": return .white.opacity(0.6)
        case "dark": return .blue.opacity(0.5)
        default: return .clear
        }
    }

    private var glowRadius: CGFloat {
        glowMode == "off" ? 0 : 8
    }

    var body: some View {
        VStack(spacing: 0) {
            if mascotVisible {
                mascotStage
            }

            if bubbleManager.isVisible {
                speechBubble
            }

            sessionArea
        }
        .frame(width: size.panelWidth)
        .onAppear {
            spriteEngine.setPet(sessionManager.pet)
            spriteEngine.setStatus(sessionManager.currentUI)
        }
        .onChange(of: sessionManager.currentUI) { _, s in spriteEngine.setStatus(s) }
        .onChange(of: sessionManager.pet) { _, p in spriteEngine.setPet(p) }
    }

    // MARK: - Mascot Stage

    private var mascotStage: some View {
        ZStack {
            let sprite = AnimatedSpriteView(engine: spriteEngine)
                .frame(width: spriteSize, height: spriteSize)
                .scaleEffect(mascotDropTargeted ? 1.08 : 1.0)
                .shadow(
                    color: mascotDropTargeted ? .orange.opacity(0.65) : .clear,
                    radius: mascotDropTargeted ? 16 : 0
                )
                .overlay {
                    if mascotDropTargeted {
                        MascotDropHalo(size: spriteSize)
                    }
                }
                .animation(.easeOut(duration: 0.18), value: mascotDropTargeted)
            if glowRadius > 0 {
                sprite.shadow(color: glowColor, radius: glowRadius)
            } else {
                sprite
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: spriteSize + (glowRadius > 0 ? 20 : 8))
        .padding(.top, 4)
        .onDrop(
            of: BucketDropHandler.supportedUTTypes,
            isTargeted: $mascotDropTargeted
        ) { providers in
            BucketDropHandler.ingest(providers: providers, source: .mascot)
        }
        .contextMenu { mascotContextMenu }
        .sheet(item: $messagePeer) { peer in
            SendMessageSheet(
                peerNickname: peer.nickname,
                onSend: { message in
                    sendMessageToPeer(peer, message: message)
                }
            )
        }
    }

    @ViewBuilder
    private var mascotContextMenu: some View {
        let peers = Array(sessionManager.peers.values)

        if !peers.isEmpty {
            Section("Send Message") {
                ForEach(peers, id: \.instanceName) { peer in
                    Button(peer.nickname) {
                        messagePeer = peer
                    }
                }
            }
        } else {
            Text("No peers nearby")
                .foregroundStyle(.secondary)
        }
    }

    private func sendMessageToPeer(_ peer: PeerInfo, message: String) {
        guard let ip = peer.ip else {
            print("[peer] no IP resolved yet for \(peer.nickname)")
            bubbleManager.show("Peer IP not resolved yet, try again in a moment", durationMs: 3000)
            return
        }

        let sender = sessionManager.nickname
        let url = "http://\(ip):\(peer.port)/peer/message"
        print("[peer] sending to \(peer.nickname) at \(url)")

        DispatchQueue.global(qos: .userInitiated).async { [weak bubbleManager] in
            guard let requestURL = URL(string: url) else { return }
            var request = URLRequest(url: requestURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 5
            request.httpBody = try? JSONSerialization.data(
                withJSONObject: ["sender": sender, "message": message]
            )
            URLSession.shared.dataTask(with: request) { _, response, error in
                if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    print("[peer] message sent to \(peer.nickname)")
                } else if let error {
                    print("[peer] send failed: \(error.localizedDescription)")
                    DispatchQueue.main.async {
                        bubbleManager?.show("Failed to send: \(error.localizedDescription)", durationMs: 4000)
                    }
                }
            }.resume()
        }
    }

    // MARK: - Speech Bubble

    private var speechBubble: some View {
        Text(bubbleManager.currentMessage ?? "")
            .font(.system(size: size.metaFont, weight: .medium))
            .foregroundStyle(isDark ? Color.white : Color.black)
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 20)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(isDark ? Color.white.opacity(0.22) : Color.white)
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 4)
            .transition(.opacity.combined(with: .scale(scale: 0.95)))
            .animation(.easeOut(duration: 0.2), value: bubbleManager.isVisible)
    }

    // MARK: - Session Area

    private var sessionArea: some View {
        VStack(spacing: 0) {
            summaryBar

            if !collapsed && !sessionManager.projects.isEmpty {
                Divider()
                    .opacity(isDark ? 0.15 : 0.2)
                    .padding(.horizontal, 10)

                projectList
            }
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
                .stroke(isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.1), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 4)
        .padding(.bottom, 4)
    }

    // MARK: - Summary Bar

    private var summaryBar: some View {
        Button {
            withAnimation(.spring(duration: 0.25)) {
                collapsed.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(isDark ? .white.opacity(0.35) : .black.opacity(0.3))

                let projects = sessionManager.projects
                if projects.isEmpty {
                    Text("no projects")
                        .font(.system(size: size.metaFont, weight: .medium))
                        .foregroundStyle(isDark ? .white.opacity(0.3) : .black.opacity(0.25))
                } else {
                    Text("\(projects.count) project\(projects.count == 1 ? "" : "s")")
                        .font(.system(size: size.metaFont, weight: .medium))
                        .foregroundStyle(isDark ? .white.opacity(0.5) : .black.opacity(0.4))
                }

                Spacer()

                if !sessionManager.projects.isEmpty {
                    statusBreakdown(sessionManager.projects)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func statusBreakdown(_ projects: [ProjectStatus]) -> some View {
        let counts = statusCounts(projects)
        HStack(spacing: 8) {
            ForEach(counts, id: \.status) { item in
                HStack(spacing: 3) {
                    Circle()
                        .fill(colorFor(item.status))
                        .frame(width: size.dotSize, height: size.dotSize)
                    Text("\(item.count)")
                        .font(.system(size: size.metaFont, weight: .medium))
                        .foregroundStyle(isDark ? .white.opacity(0.45) : .black.opacity(0.4))
                }
            }
        }
    }

    private struct StatusCount {
        let status: Status
        let count: Int
    }

    private func statusCounts(_ projects: [ProjectStatus]) -> [StatusCount] {
        var map: [Status: Int] = [:]
        for p in projects { map[p.status, default: 0] += 1 }
        return map.sorted { a, b in
            if a.key == .idle { return false }
            if b.key == .idle { return true }
            return a.key.priority > b.key.priority
        }
        .map { StatusCount(status: $0.key, count: $0.value) }
    }

    // MARK: - Project List

    private var projectList: some View {
        VStack(spacing: 2) {
            ForEach(sessionManager.projects) { project in
                projectRow(project)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func projectRow(_ project: ProjectStatus) -> some View {
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(colorFor(project.status))
                .frame(width: 3)
                .padding(.vertical, 6)
                .padding(.leading, 2)

            HStack(spacing: 6) {
                Text(project.name)
                    .font(.system(size: size.projectFont, weight: .medium))
                    .foregroundStyle(isDark ? .white.opacity(0.85) : .black.opacity(0.8))
                    .lineLimit(1)

                Spacer()

                if project.status == .busy {
                    // Busy gets an animated "Working..." — three dots pulse
                    // one-at-a-time so the width stays stable and the state
                    // visually reads as "in progress" instead of frozen.
                    AnimatedWorkingLabel(
                        font: .system(size: size.metaFont, weight: .medium),
                        color: colorFor(project.status).opacity(0.8)
                    )
                } else if project.status != .idle {
                    Text(project.status.displayLabel)
                        .font(.system(size: size.metaFont, weight: .medium))
                        .foregroundStyle(colorFor(project.status).opacity(0.8))
                }
            }
            .padding(.leading, 8)
            .padding(.trailing, 10)
        }
        .frame(height: size.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isDark ? Color.white.opacity(0.04) : Color.black.opacity(0.03))
        )
        .help(
            tooltipText(
                snapshot: awayDigest?.snapshot(for: project.path),
                enabled: awayDigest?.enabled ?? false
            )
        )
        .onTapGesture {
            openInVSCode(path: project.path)
        }
        .contextMenu {
            Button("Open in VS Code") { openInVSCode(path: project.path) }
            Button("Open in Terminal") { openInTerminal(path: project.path) }
            Button("Reveal in Finder") {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.path)
            }
            Divider()
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(project.path, forType: .string)
            }
            if awayDigest?.snapshot(for: project.path) != nil {
                Divider()
                Button("Clear digest") {
                    awayDigest?.clearDigest(for: project.path)
                }
            }
        }
    }

    // MARK: - Helpers

    private func colorFor(_ status: Status) -> Color {
        switch status {
        case .busy:         return Color(red: 1.0, green: 0.42, blue: 0.42)
        case .idle:         return Color(red: 0.3, green: 0.85, blue: 0.39)
        case .service:      return Color(red: 0.37, green: 0.36, blue: 0.9)
        case .searching, .initializing:
                            return Color(red: 1.0, green: 0.85, blue: 0.24)
        case .disconnected: return Color(red: 0.39, green: 0.39, blue: 0.4)
        case .visiting:     return .teal
        case .carrying:     return .orange
        }
    }

    private func openInVSCode(path: String) {
        let url = URL(fileURLWithPath: path)
        for bid in ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.vscodium"] {
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
                let config = NSWorkspace.OpenConfiguration()
                NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: config)
                return
            }
        }
        NSWorkspace.shared.open(url)
    }

    private func openInTerminal(path: String) {
        let escaped = path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"Terminal\" to do script \"cd \\\"\(escaped)\\\"\""
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
    }
}

// MARK: - Send Message Sheet

private struct SendMessageSheet: View {
    let peerNickname: String
    let onSend: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var message = ""

    var body: some View {
        VStack(spacing: 12) {
            Text("Message \(peerNickname)")
                .font(.headline)

            TextField("Type a message...", text: $message)
                .textFieldStyle(.roundedBorder)
                .onSubmit { send() }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Send") { send() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(message.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 280)
    }

    private func send() {
        let trimmed = message.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        onSend(trimmed)
        dismiss()
    }
}

// MARK: - NSVisualEffectView Wrapper

struct VisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
