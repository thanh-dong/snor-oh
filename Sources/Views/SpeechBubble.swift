import SwiftUI

/// A speech bubble that auto-dismisses after a set duration.
struct SpeechBubble: View {
    let message: String
    let isVisible: Bool

    var body: some View {
        if isVisible {
            Text(message)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.ultraThinMaterial)
                        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                }
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.8, anchor: .bottom)),
                    removal: .opacity
                ))
        }
    }
}

/// Manages speech bubble state: message queue, auto-dismiss timer, and trigger sources.
/// Observed by MascotView for display.
@Observable
final class BubbleManager {

    private(set) var currentMessage: String?
    private(set) var isVisible: Bool = false

    private var dismissTimer: Timer?

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
        dismissTimer?.invalidate()
        currentMessage = message
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

    /// Dismiss the current bubble.
    func dismiss() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        isVisible = false
    }
}
