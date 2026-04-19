import SwiftUI

/// Root mascot view: animated sprite + status pill + speech bubble.
struct MascotView: View {
    let sessionManager: SessionManager
    let spriteEngine: SpriteEngine
    let bubbleManager: BubbleManager

    @AppStorage(DefaultsKey.displayScale) private var displayScale = 1.0
    @AppStorage(DefaultsKey.glowMode) private var glowMode = "off"

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

            // Animated sprite with glow effect
            AnimatedSpriteView(engine: spriteEngine)
                .frame(width: spriteSize, height: spriteSize)
                .shadow(color: glowColor, radius: glowMode == "off" ? 0 : 12)
                .onDrop(of: BucketDropHandler.supportedUTTypes, isTargeted: nil) { providers in
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
