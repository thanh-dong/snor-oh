import SwiftUI

/// Root mascot view: animated sprite + status pill + speech bubble.
struct MascotView: View {
    let sessionManager: SessionManager
    let spriteEngine: SpriteEngine
    let bubbleManager: BubbleManager

    @AppStorage(DefaultsKey.displayScale) private var displayScale = 1.0
    @AppStorage(DefaultsKey.glowMode) private var glowMode = "off"
    @State private var dropTargeted = false
    @State private var bucketManager = BucketManager.shared

    /// Epic 02 — opacity of the orange "catch" overlay. Animates 0 → 1 → 0
    /// across ~400 ms when `.bucketChanged` fires with `change == "added"`.
    /// Tint is intensified when `source == "mascot"` (the drop landed here).
    @State private var catchFlashOpacity: Double = 0
    @State private var catchFlashTint: Color = .orange

    private var spriteSize: CGFloat { SpriteConfig.frameBasePx * displayScale }

    /// Status the sprite engine should render — promoted to `.carrying` when
    /// the bucket has items and no Claude Code activity is demanding the
    /// sprite. Pure function on `Status` — see `Status.resolveDisplay`.
    private var displayStatus: Status {
        Status.resolveDisplay(
            sessionStatus: sessionManager.currentUI,
            bucketCount: bucketManager.totalActiveItemCount()
        )
    }

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
                isVisible: bubbleManager.isVisible,
                onTap: bubbleManager.tapAction
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
                // Epic 02: orange "catch" flash when a new bucket item arrives.
                // Non-interactive, disappears on its own.
                .overlay {
                    Circle()
                        .fill(catchFlashTint)
                        .frame(width: spriteSize * 0.95, height: spriteSize * 0.95)
                        .blendMode(.plusLighter)
                        .opacity(catchFlashOpacity)
                        .allowsHitTesting(false)
                }
                // Epic 02: inventory badge (top-right).
                .overlay(alignment: .topTrailing) {
                    BucketBadgeView(scale: displayScale)
                        .offset(x: spriteSize * 0.12, y: -spriteSize * 0.08)
                        .allowsHitTesting(false)
                }
                .animation(.easeOut(duration: 0.18), value: dropTargeted)
                .onDrop(
                    of: BucketDropHandler.supportedUTTypes,
                    isTargeted: $dropTargeted
                ) { providers in
                    BucketDropHandler.ingest(providers: providers, source: .mascot)
                }
                .onReceive(NotificationCenter.default.publisher(for: .bucketChanged)) { note in
                    handleBucketChanged(note)
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
            spriteEngine.setStatus(displayStatus)
        }
        .onChange(of: displayStatus) { _, newStatus in
            spriteEngine.setStatus(newStatus)
        }
        .onChange(of: sessionManager.pet) { _, newPet in
            spriteEngine.setPet(newPet)
        }
    }

    // MARK: - Epic 02 catch reaction

    /// Plays the one-shot catch overlay on every `.bucketChanged` whose
    /// `change == "added"`. Ignores pins, removals, bucket CRUD, etc. so the
    /// flash only fires when something *lands* in a bucket.
    private func handleBucketChanged(_ note: Notification) {
        guard let changeRaw = note.userInfo?["change"] as? String,
              changeRaw == BucketChangeKind.added.rawValue else { return }
        let source = note.userInfo?["source"] as? String
        let fromMascot = source == BucketChangeSource.mascot.rawValue
        // Mascot-origin drops get a brighter, slightly warmer tint so the
        // hero interaction feels like the pet "grabbed" the item.
        catchFlashTint = fromMascot ? Color(red: 1.0, green: 0.75, blue: 0.35) : .orange
        // Ramp in quickly, then fade over ~350 ms — total ~400 ms.
        catchFlashOpacity = 0
        withAnimation(.easeOut(duration: 0.08)) {
            catchFlashOpacity = fromMascot ? 0.55 : 0.35
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            withAnimation(.easeOut(duration: 0.32)) {
                catchFlashOpacity = 0
            }
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
