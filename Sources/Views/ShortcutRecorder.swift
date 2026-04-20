import SwiftUI
import AppKit

/// Minimal keyboard-shortcut capture control. Click → enters recording mode
/// → captures next non-modifier keypress → writes binding back.
///
/// Modifier-only presses are ignored (standard behavior — a modifier alone
/// isn't a binding). Escape cancels recording without changing the value.
///
/// Emits via the `binding` closure; the owning view is responsible for
/// persisting via `BucketManager.updateSettings`. We don't talk to the
/// manager directly so this control stays reusable.
@MainActor
struct ShortcutRecorder: View {
    let label: String
    let binding: HotkeyBinding
    let onChange: (HotkeyBinding) -> Void
    let defaultBinding: HotkeyBinding

    @State private var recording: Bool = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 12))
            Spacer()
            Button(action: toggleRecording) {
                Text(displayText)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .frame(minWidth: 110)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(recording
                                  ? Color.accentColor.opacity(0.25)
                                  : Color.secondary.opacity(0.12))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(recording ? Color.accentColor : Color.clear, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)

            Button("Reset") {
                onChange(defaultBinding)
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        .onDisappear(perform: stopMonitor)
    }

    private var displayText: String {
        if recording { return "Press a shortcut…" }
        return HotkeyFormatter.describe(binding)
    }

    private func toggleRecording() {
        recording.toggle()
        if recording {
            startMonitor()
        } else {
            stopMonitor()
        }
    }

    private func startMonitor() {
        stopMonitor()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Escape = cancel without change.
            if event.keyCode == 53 {
                Task { @MainActor in
                    recording = false
                    stopMonitor()
                }
                return nil
            }
            guard let captured = HotkeyFormatter.parse(event: event) else {
                return nil  // ignore modifier-only presses, etc.
            }
            Task { @MainActor in
                onChange(captured)
                recording = false
                stopMonitor()
            }
            return nil
        }
    }

    private func stopMonitor() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }
}

// MARK: - Formatter

/// Converts between `NSEvent` keyDowns and `HotkeyBinding`, and renders a
/// binding as a human-readable glyph string (⌘⇧B etc.).
enum HotkeyFormatter {

    /// Parses an NSEvent into a HotkeyBinding, or nil if the event carries
    /// no primary key (e.g. user pressed only a modifier).
    static func parse(event: NSEvent) -> HotkeyBinding? {
        // We need at least one non-modifier character.
        guard let chars = event.charactersIgnoringModifiers?.uppercased(),
              !chars.isEmpty else { return nil }
        // Reject function/arrow keys for now — the Carbon registrar's key
        // table only supports letters + digits. Future extension: grow the
        // table and map these.
        let first = String(chars.prefix(1))
        guard HotkeyRegistrar.keyCode(for: first) != nil else { return nil }

        var mods: Set<HotkeyBinding.Modifier> = []
        let f = event.modifierFlags
        if f.contains(.command) { mods.insert(.command) }
        if f.contains(.option)  { mods.insert(.option) }
        if f.contains(.control) { mods.insert(.control) }
        if f.contains(.shift)   { mods.insert(.shift) }
        // Require at least one modifier so bindings are reachable from any
        // focused control (a lone letter would collide with typing).
        guard !mods.isEmpty else { return nil }

        return HotkeyBinding(key: first, modifiers: mods)
    }

    /// Human-readable glyph string, e.g. ⌘⇧B.
    static func describe(_ binding: HotkeyBinding) -> String {
        var out = ""
        // Apple order: ⌃⌥⇧⌘ (control, option, shift, command).
        if binding.modifiers.contains(.control) { out += "⌃" }
        if binding.modifiers.contains(.option)  { out += "⌥" }
        if binding.modifiers.contains(.shift)   { out += "⇧" }
        if binding.modifiers.contains(.command) { out += "⌘" }
        out += binding.key.uppercased()
        return out
    }
}
