import AppKit
import SwiftUI

/// A speech bubble that auto-dismisses after a set duration.
///
/// When `onTap` is non-nil (Epic 02 heavy bubble), the bubble becomes
/// interactive and shows a subtle highlight tint so the user knows it clicks.
struct SpeechBubble: View {
    let message: String
    let isVisible: Bool
    var onTap: (() -> Void)? = nil

    var body: some View {
        if isVisible {
            let base = Text(message)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.ultraThinMaterial)
                        .overlay {
                            if onTap != nil {
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.orange.opacity(0.65), lineWidth: 1.5)
                            }
                        }
                        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                }
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.8, anchor: .bottom)),
                    removal: .opacity
                ))
            if let onTap {
                base
                    .onTapGesture { onTap() }
                    .accessibilityAddTraits(.isButton)
            } else {
                base
            }
        }
    }
}

/// Manages speech bubble state: message queue, auto-dismiss timer, and trigger sources.
/// Observed by MascotView for display.
@Observable
final class BubbleManager {

    private(set) var currentMessage: String?
    private(set) var isVisible: Bool = false

    /// Epic 02 — non-nil when the current bubble is actionable (e.g. the
    /// "I'm heavy!" bubble opens the bucket window on tap). MascotView wires
    /// this into a `SpeechBubble.onTap` so only the heavy bubble is clickable.
    /// Cleared on every `show()` and `dismiss()`.
    private(set) var tapAction: (() -> Void)?

    private var dismissTimer: Timer?
    private var userReturnedObserver: NSObjectProtocol?

    init() {
        userReturnedObserver = NotificationCenter.default.addObserver(
            forName: .userReturned, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleUserReturned() }
        }
    }

    deinit {
        if let obs = userReturnedObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    // MARK: - Bubble Sources

    static let taskCompletedMessages = [
        "All done!",
        "Task complete!",
        "Finished!",
        "Done and dusted!",
        "Mission accomplished!",
        "Another one done!",
    ]

    private static let welcomeMessages = [
        "Hey there! Ready to code?",
        "Let's build something cool!",
        "Good to see you!",
    ]

    /// Show a speech bubble with auto-dismiss.
    func show(_ message: String, durationMs: UInt64 = 7000) {
        showInternal(message, durationMs: durationMs, onTap: nil)
    }

    /// Epic 02 — shows an *actionable* bubble. Tapping it runs `onTap` and
    /// dismisses. Used for the "I'm heavy!" bubble which opens the bucket.
    func showActionable(_ message: String, durationMs: UInt64 = 8000, onTap: @escaping () -> Void) {
        showInternal(message, durationMs: durationMs) { [weak self] in
            onTap()
            self?.dismiss()
        }
    }

    private func showInternal(_ message: String, durationMs: UInt64, onTap: (() -> Void)?) {
        dismissTimer?.invalidate()
        currentMessage = message
        tapAction = onTap
        isVisible = true
        let duration = TimeInterval(durationMs) / 1000.0
        let t = Timer(timeInterval: duration, repeats: false) { [weak self] _ in
            self?.dismiss()
        }
        RunLoop.main.add(t, forMode: .common)
        dismissTimer = t
    }

    /// Show a random welcome message (respects bubbleEnabled setting).
    func showWelcome() {
        guard UserDefaults.standard.object(forKey: DefaultsKey.bubbleEnabled) as? Bool ?? true else { return }
        if let msg = Self.welcomeMessages.randomElement() {
            show(msg, durationMs: 5000)
        }
    }

    /// Show a random task-completed message (respects bubbleEnabled setting).
    func showTaskCompleted() {
        guard UserDefaults.standard.object(forKey: DefaultsKey.bubbleEnabled) as? Bool ?? true else { return }
        if let msg = Self.taskCompletedMessages.randomElement() {
            show(msg, durationMs: 4000)
        }
    }

    @MainActor
    private func handleUserReturned() {
        // Observer ordering: BubbleManager subscribes before AwayDigestCollector
        // (BubbleManager is instantiated at AppDelegate class-level init; the
        // collector is instantiated inside applicationDidFinishLaunching). Both
        // use a `Task { @MainActor in ... }` hop, and the one enqueued first runs
        // first. Without this second hop, we would call `welcomeBackSummary()`
        // BEFORE the collector has set `windowEnd`, and every digest would read
        // as empty. The second hop re-enqueues us behind the collector's task,
        // so by the time we run, `windowEnd` is populated and snapshots work.
        Task { @MainActor [weak self] in
            let collector = (NSApp.delegate as? AppDelegate)?.awayDigestCollector
            guard let msg = collector?.welcomeBackSummary() else { return }
            self?.show(msg, durationMs: 8000)
        }
    }

    /// Dismiss the current bubble.
    func dismiss() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        isVisible = false
        tapAction = nil
    }
}
