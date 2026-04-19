import SwiftUI
import AppKit

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

    @AppStorage(DefaultsKey.panelSize) private var sizeRaw = "regular"
    @AppStorage(DefaultsKey.sidebarCollapsed) private var collapsed = false
    @AppStorage(DefaultsKey.theme) private var theme = "dark"
    @AppStorage(DefaultsKey.displayScale) private var displayScale = 1.0
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
            // Mascot stage — transparent, floating
            mascotStage

            // Speech bubble
            if bubbleManager.isVisible {
                speechBubble
            }

            // Session area — has its own background
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

    // MARK: - Mascot Stage (transparent)

    private var mascotStage: some View {
        ZStack {
            AnimatedSpriteView(engine: spriteEngine)
                .frame(width: spriteSize, height: spriteSize)
                .shadow(color: glowColor, radius: glowRadius)
        }
        .frame(maxWidth: .infinity)
        .frame(height: spriteSize + (glowRadius > 0 ? 20 : 8))
        .padding(.top, 4)
    }

    // MARK: - Speech Bubble

    private var speechBubble: some View {
        Text(bubbleManager.currentMessage ?? "")
            .font(.system(size: size.metaFont, weight: .medium))
            .foregroundStyle(isDark ? .white.opacity(0.7) : .black.opacity(0.6))
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 20)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.06))
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 4)
            .transition(.opacity.combined(with: .scale(scale: 0.95)))
            .animation(.easeOut(duration: 0.2), value: bubbleManager.isVisible)
    }

    // MARK: - Session Area (with background)

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
                    Text("no sessions")
                        .font(.system(size: size.metaFont, weight: .medium))
                        .foregroundStyle(isDark ? .white.opacity(0.3) : .black.opacity(0.25))
                } else {
                    Text("\(projects.count) session\(projects.count == 1 ? "" : "s")")
                        .font(.system(size: size.metaFont, weight: .medium))
                        .foregroundStyle(isDark ? .white.opacity(0.5) : .black.opacity(0.4))

                    statusBreakdown(projects)
                }

                Spacer()
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
            // Status rail — left edge colored bar
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

                if project.status != .idle {
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
