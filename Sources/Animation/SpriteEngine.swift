import AppKit
import CoreGraphics

/// Drives sprite sheet animation via a display-link-style timer.
/// Renders frames into an NSImageView's layer.
///
/// Usage:
///   let engine = SpriteEngine()
///   engine.attach(to: imageView)
///   engine.setPet("sprite")
///   engine.setStatus(.busy)
///
/// Main-thread only.
@Observable
final class SpriteEngine {

    // MARK: - Public State (observed by SwiftUI)

    /// The current frame image for display. SwiftUI observes this.
    private(set) var currentFrame: CGImage?

    // MARK: - Configuration

    private var pet: String = "sprite"
    private var status: Status = .initializing
    private var frames: [CGImage] = []
    private var frameIndex: Int = 0

    // MARK: - Timer

    private var timer: Timer?
    private var frozen = false
    private var freezeTimer: Timer?

    // MARK: - API

    func setPet(_ newPet: String) {
        guard newPet != pet else { return }
        pet = newPet
        reloadFrames()
    }

    func setStatus(_ newStatus: Status) {
        guard newStatus != status else { return }
        status = newStatus
        reloadFrames()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        freezeTimer?.invalidate()
        freezeTimer = nil
    }

    // MARK: - Internal

    private func reloadFrames() {
        // Cancel freeze
        frozen = false
        freezeTimer?.invalidate()
        freezeTimer = nil

        // Load frames for new pet/status
        frames = SpriteCache.shared.frames(pet: pet, status: status)
        frameIndex = 0

        if frames.isEmpty {
            currentFrame = nil
            stopAnimation()
            return
        }

        currentFrame = frames[0]
        startAnimation()
        scheduleAutoFreeze()
    }

    private func startAnimation() {
        timer?.invalidate()
        guard frames.count > 1 else {
            // Single frame — no animation needed
            return
        }
        let t = Timer(timeInterval: SpriteConfig.frameDurationMs / 1000.0, repeats: true) { [weak self] _ in
            self?.advanceFrame()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopAnimation() {
        timer?.invalidate()
        timer = nil
    }

    private func advanceFrame() {
        guard !frozen, !frames.isEmpty else { return }
        frameIndex = (frameIndex + 1) % frames.count
        currentFrame = frames[frameIndex]
    }

    private func scheduleAutoFreeze() {
        guard SpriteConfig.autoFreezeStatuses.contains(status) else { return }
        let t = Timer(timeInterval: SpriteConfig.autoFreezeTimeout, repeats: false) { [weak self] _ in
            self?.freeze()
        }
        RunLoop.main.add(t, forMode: .common)
        freezeTimer = t
    }

    private func freeze() {
        frozen = true
        // Show last frame
        if !frames.isEmpty {
            frameIndex = frames.count - 1
            currentFrame = frames[frameIndex]
        }
        stopAnimation()
    }
}
