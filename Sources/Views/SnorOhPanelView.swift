import SwiftUI
import AppKit

// MARK: - Panel Size

/// Configurable size tiers for the session panel, inspired by snor-oh.
enum SnorOhSize: String, CaseIterable {
    case compact
    case regular
    case large

    var rowHeight: CGFloat {
        switch self {
        case .compact: return 28
        case .regular: return 32
        case .large:   return 36
        }
    }

    var panelWidth: CGFloat {
        switch self {
        case .compact: return 300
        case .regular: return 360
        case .large:   return 420
        }
    }

    var projectFont: CGFloat {
        switch self {
        case .compact: return 13
        case .regular: return 15
        case .large:   return 16
        }
    }

    var metaFont: CGFloat {
        switch self {
        case .compact: return 10
        case .regular: return 11
        case .large:   return 12
        }
    }

    var dotSize: CGFloat {
        switch self {
        case .compact: return 6
        case .regular: return 7
        case .large:   return 8
        }
    }

    var cardCornerRadius: CGFloat {
        switch self {
        case .compact: return 10
        case .regular: return 12
        case .large:   return 14
        }
    }

    var headerSpriteSize: CGFloat {
        switch self {
        case .compact: return 56
        case .regular: return 72
        case .large:   return 88
        }
    }
}

// MARK: - Panel View

/// Compact unified panel: small mascot in header, session cards below.
/// Designed to stay tiny and unobtrusive on the desktop.
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

    /// Header mascot size = base tier size * user display scale.
    private var mascotSize: CGFloat {
        size.headerSpriteSize * displayScale
    }

    private var glowColor: Color {
        switch glowMode {
        case "light": return .white.opacity(0.6)
        case "dark": return .blue.opacity(0.5)
        default: return .clear
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            panelHeader

            // Speech bubble (temporary, only when visible)
            if bubbleManager.isVisible {
                speechBubbleRow
            }

            if !collapsed {
                if sessionManager.projects.isEmpty {
                    emptyState
                } else {
                    contentArea
                }
            }
        }
        .frame(width: size.panelWidth)
        .background(
            VisualEffectBackground(
                material: isDark ? .hudWindow : .sidebar,
                blendingMode: .behindWindow
            )
            .clipShape(RoundedRectangle(cornerRadius: 14))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.08), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .onAppear {
            spriteEngine.setPet(sessionManager.pet)
            spriteEngine.setStatus(sessionManager.currentUI)
        }
        .onChange(of: sessionManager.currentUI) { _, newStatus in
            spriteEngine.setStatus(newStatus)
        }
        .onChange(of: sessionManager.pet) { _, newPet in
            spriteEngine.setPet(newPet)
        }
    }

    // MARK: - Header (title + count + collapse)

    private var panelHeader: some View {
        HStack(spacing: 8) {
            Text("snor-oh")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(isDark ? .white.opacity(0.7) : .black.opacity(0.6))

            // Count badge
            Text("\(sessionManager.projects.count)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(isDark ? .white.opacity(0.6) : .black.opacity(0.5))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule()
                        .fill(isDark ? Color.white.opacity(0.1) : Color.black.opacity(0.08))
                )

            Spacer()

            // Overall status dot
            Circle()
                .fill(overallStatusColor)
                .frame(width: 8, height: 8)

            Button {
                withAnimation(.spring(duration: 0.25)) {
                    collapsed.toggle()
                }
            } label: {
                Image(systemName: collapsed ? "chevron.down" : "chevron.up")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(isDark ? .white.opacity(0.5) : .black.opacity(0.4))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    // MARK: - Speech Bubble Row

    private var speechBubbleRow: some View {
        Text(bubbleManager.currentMessage ?? "")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(isDark ? .white.opacity(0.7) : .black.opacity(0.6))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isDark ? Color.white.opacity(0.04) : Color.black.opacity(0.03))
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .move(edge: .top)),
                removal: .opacity
            ))
            .animation(.easeOut(duration: 0.2), value: bubbleManager.isVisible)
    }

    // MARK: - Status Color

    private var overallStatusColor: Color {
        switch sessionManager.currentUI {
        case .busy:         return Color(red: 1.0, green: 0.42, blue: 0.42)
        case .idle:         return Color(red: 0.3, green: 0.85, blue: 0.39)
        case .service:      return Color(red: 0.37, green: 0.36, blue: 0.9)
        case .searching, .initializing:
                            return Color(red: 1.0, green: 0.85, blue: 0.24)
        case .disconnected: return Color(red: 0.39, green: 0.39, blue: 0.4)
        case .visiting:     return .teal
        }
    }

    // MARK: - Empty State (mascot only, no sessions)

    private var emptyState: some View {
        VStack(spacing: 6) {
            AnimatedSpriteView(engine: spriteEngine)
                .frame(width: spriteSize, height: spriteSize)
                .shadow(color: glowColor, radius: glowMode == "off" ? 0 : 8)
            Text("No active sessions")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isDark ? .white.opacity(0.3) : .black.opacity(0.25))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .padding(.bottom, 4)
    }

    // MARK: - Content Area (mascot left + project list right)

    /// Fixed square container size for the mascot, based on panel size tier.
    private var mascotContainerSize: CGFloat {
        switch size {
        case .compact: return 72
        case .regular: return 88
        case .large:   return 104
        }
    }

    /// Inset for glow room — sprite is this much smaller than container on each side.
    private var glowInset: CGFloat { glowMode == "off" ? 4 : 10 }

    /// Sprite size: scale-aware, but clamped to fit within container minus glow inset.
    private var spriteSize: CGFloat {
        let maxSprite = mascotContainerSize - glowInset * 2
        return min(mascotSize, maxSprite)
    }

    private var contentArea: some View {
        HStack(alignment: .center, spacing: 0) {
            // Fixed square container — sprite centered with glow room
            ZStack {
                AnimatedSpriteView(engine: spriteEngine)
                    .frame(width: spriteSize, height: spriteSize)
                    .shadow(color: glowColor, radius: glowMode == "off" ? 0 : 8)
            }
            .frame(width: mascotContainerSize, height: mascotContainerSize)

            // Project list
            VStack(spacing: 4) {
                ForEach(sessionManager.projects) { project in
                    SnorOhCard(project: project, size: size, isDark: isDark)
                }
            }
            .padding(.trailing, 8)
            .padding(.vertical, 6)
        }
        .padding(.bottom, 4)
    }
}

// MARK: - Project Card

/// Per-project card with large animated sprite, snor-oh-style layout.
struct SnorOhCard: View {
    let project: ProjectStatus
    let size: SnorOhSize
    let isDark: Bool

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Text(project.name)
                .font(.system(size: size.projectFont, weight: .semibold))
                .foregroundStyle(isDark ? .white.opacity(0.9) : .black.opacity(0.85))
                .lineLimit(1)

            Spacer()

            // Only show status pill when not idle
            if project.status != .idle {
                statusPill
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .frame(height: size.rowHeight)
        .background(cardBackground)
        // Status rail (right edge colored bar)
        .overlay(alignment: .trailing) {
            RoundedRectangle(cornerRadius: 2)
                .fill(statusColor)
                .frame(width: 3)
                .padding(.vertical, 8)
        }
        // Close button (top-right, visible on hover)
        .overlay(alignment: .topTrailing) {
            if isHovered {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(isDark ? .white.opacity(0.4) : .black.opacity(0.35))
                    .frame(width: 16, height: 16)
                    .background(
                        Circle()
                            .fill(isDark ? Color.white.opacity(0.1) : Color.black.opacity(0.08))
                    )
                    .padding(6)
                    .transition(.opacity)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: size.cardCornerRadius))
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .onTapGesture {
            openInVSCode(path: project.path)
        }
        .contextMenu {
            Button("Open in VS Code") { openInVSCode(path: project.path) }
            Button("Open in Terminal") { openInTerminal(path: project.path) }
            Button("Reveal in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.path) }
            Divider()
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(project.path, forType: .string)
            }
        }
    }

    // MARK: - Card Background

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: size.cardCornerRadius)
            .fill(
                LinearGradient(
                    colors: isHovered
                        ? [isDark ? Color.white.opacity(0.10) : Color.black.opacity(0.06),
                           isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.03)]
                        : [isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.04),
                           isDark ? Color.white.opacity(0.03) : Color.black.opacity(0.02)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
    }

    // MARK: - Status Pill

    private var statusPill: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: size.dotSize, height: size.dotSize)

            Text(project.status.displayLabel)
                .font(.system(size: size.metaFont, weight: .medium))
                .foregroundStyle(statusColor)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(statusColor.opacity(isDark ? 0.15 : 0.12))
        )
    }

    // MARK: - Helpers

    private var statusColor: Color {
        switch project.status {
        case .busy:         return Color(red: 1.0, green: 0.42, blue: 0.42)  // #ff6b6b
        case .idle:         return Color(red: 0.3, green: 0.85, blue: 0.39)  // #4cd964
        case .service:      return Color(red: 0.37, green: 0.36, blue: 0.9)  // #5e5ce6
        case .searching, .initializing:
                            return Color(red: 1.0, green: 0.85, blue: 0.24)  // #ffd93d
        case .disconnected: return Color(red: 0.39, green: 0.39, blue: 0.4)  // #636366
        case .visiting:     return .teal
        }
    }

    private func openInVSCode(path: String) {
        let url = URL(fileURLWithPath: path)
        let bundleIDs = [
            "com.microsoft.VSCode",
            "com.microsoft.VSCodeInsiders",
            "com.vscodium",
        ]
        for bundleID in bundleIDs {
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
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
