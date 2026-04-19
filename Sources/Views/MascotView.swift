import SwiftUI

/// Root mascot view: animated sprite + status pill + speech bubble.
struct MascotView: View {
    let sessionManager: SessionManager
    let spriteEngine: SpriteEngine
    let bubbleManager: BubbleManager

    @AppStorage(DefaultsKey.displayScale) private var displayScale = 1.0
    @AppStorage(DefaultsKey.glowMode) private var glowMode = "off"
    @State private var dropTargeted = false

    private var spriteSize: CGFloat { SpriteConfig.frameBasePx * displayScale }

    /// Glow shadow color based on glowMode setting.
    private var glowColor: Color {
        switch glowMode {
        case "light": return .white.opacity(0.6)
        case "dark": return .blue.opacity(0.5)
        default: return .clear
        }
    }

    var body: some View {
        VStack(spacing: 4) {
            // Speech bubble (above sprite)
            SpeechBubble(
                message: bubbleManager.currentMessage ?? "",
                isVisible: bubbleManager.isVisible
            )
            .animation(.easeOut(duration: 0.2), value: bubbleManager.isVisible)
            .frame(height: 30)

            // Animated sprite with glow effect + drop-target placeholder
            AnimatedSpriteView(engine: spriteEngine)
                .frame(width: spriteSize, height: spriteSize)
                .shadow(color: glowColor, radius: glowMode == "off" ? 0 : 12)
                .scaleEffect(dropTargeted ? 1.08 : 1.0)
                .shadow(
                    color: dropTargeted ? .orange.opacity(0.65) : .clear,
                    radius: dropTargeted ? 16 : 0
                )
                .overlay {
                    if dropTargeted {
                        MascotDropHalo(size: spriteSize)
                    }
                }
                .animation(.easeOut(duration: 0.18), value: dropTargeted)
                .onDrop(
                    of: BucketDropHandler.supportedUTTypes,
                    isTargeted: $dropTargeted
                ) { providers in
                    BucketDropHandler.ingest(providers: providers, source: .mascot)
                }

            // Status pill
            StatusPill(status: sessionManager.currentUI)

            // Visitors (if any)
            if !sessionManager.visitors.isEmpty {
                HStack(spacing: 4) {
                    ForEach(sessionManager.visitors.prefix(3)) { visitor in
                        VisitorSprite(pet: visitor.pet)
                            .frame(width: 40, height: 40)
                    }
                }
                .frame(height: 50)
            }
        }
        .frame(
            width: MascotView.windowWidth(scale: displayScale),
            height: MascotView.windowHeight(scale: displayScale, hasVisitors: !sessionManager.visitors.isEmpty)
        )
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

    // MARK: - Window Size Helpers

    /// Base non-sprite width padding (250 - 128 = 122).
    private static let widthPadding: CGFloat = 122
    /// Base non-sprite height (bubble 30 + pill ~30 + spacing ~32 = 92).
    private static let heightPadding: CGFloat = 92

    static func windowWidth(scale: CGFloat) -> CGFloat {
        max(250, SpriteConfig.frameBasePx * scale + widthPadding)
    }

    static func windowHeight(scale: CGFloat, hasVisitors: Bool) -> CGFloat {
        SpriteConfig.frameBasePx * scale + heightPadding + (hasVisitors ? 60 : 0)
    }
}

/// Drop-target halo that appears around the mascot while the user is
/// dragging content over it. Also used by `SnorOhPanelView.mascotStage`.
///
/// Renders a pulsing orange ring + a small "+" badge so it's obvious the
/// mascot will accept the drop.
struct MascotDropHalo: View {
    let size: CGFloat

    @State private var pulse = false

    var body: some View {
        ZStack {
            // Outer pulsing ring
            Circle()
                .stroke(Color.orange.opacity(0.85), lineWidth: 3)
                .frame(width: size * 1.15, height: size * 1.15)
                .scaleEffect(pulse ? 1.06 : 1.0)
                .opacity(pulse ? 0.6 : 1.0)

            // Soft fill inside the ring
            Circle()
                .fill(Color.orange.opacity(0.10))
                .frame(width: size * 1.15, height: size * 1.15)

            // "+" affordance in the top-right
            Image(systemName: "plus.circle.fill")
                .font(.system(size: max(14, size * 0.22), weight: .semibold))
                .foregroundStyle(.white, .orange)
                .offset(x: size * 0.42, y: -size * 0.42)
                .shadow(color: .black.opacity(0.25), radius: 2)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.92)))
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}

/// Renders the current sprite frame from the SpriteEngine.
/// Uses Image(decorative:) for zero-allocation CGImage display.
struct AnimatedSpriteView: View {
    let engine: SpriteEngine

    var body: some View {
        Group {
            if let cgImage = engine.currentFrame {
                Image(decorative: cgImage, scale: 1.0, orientation: .up)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
            } else {
                // Fallback when no sprite loaded
                Circle()
                    .fill(.gray.opacity(0.3))
            }
        }
    }
}
