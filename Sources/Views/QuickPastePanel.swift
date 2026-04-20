import AppKit
import SwiftUI

/// Non-activating NSPanel used by ⌘⇧V quick paste.
///
/// Design constraints driven by macOS:
///   - `.nonactivatingPanel` + `becomesKeyOnlyIfNeeded` so the user's target
///     app stays frontmost — `synthesizeCommandV` pastes into the RIGHT app.
///   - We install a local keyboard monitor (not firstResponder) so arrow
///     keys / Return / Esc work even though the panel doesn't steal focus.
///   - `hidesOnDeactivate = true` so clicking away dismisses the popup.
@MainActor
final class QuickPastePanel: NSPanel {

    private var keyMonitor: Any?
    private var onSelect: (Int) -> Void = { _ in }
    private var onCancel: () -> Void = {}
    private var itemCount: Int = 0
    private var selectedIndex: Int = 0
    private var setSelection: (Int) -> Void = { _ in }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        hasShadow = true
        isMovableByWindowBackground = false
        isOpaque = false
        backgroundColor = .clear
        hidesOnDeactivate = true
    }

    /// Display the panel centered on the currently active screen with
    /// `items`. The callbacks fire when the user picks an index (`Return` /
    /// click) or cancels (`Esc` / click-outside).
    func show(
        items: [BucketItem],
        sidecarRoot: URL,
        onSelect: @escaping (Int) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.onSelect = onSelect
        self.onCancel = onCancel
        self.itemCount = items.count
        self.selectedIndex = 0

        // SwiftUI host — a Binding-bridged selection lets the keyboard
        // monitor update the view without the view owning the state.
        let selectionGetter: () -> Int = { [weak self] in self?.selectedIndex ?? 0 }
        let selectionSetter: (Int) -> Void = { [weak self] idx in
            self?.selectedIndex = idx
        }
        self.setSelection = selectionSetter

        let view = QuickPasteView(
            items: items,
            sidecarRoot: sidecarRoot,
            getSelection: selectionGetter,
            setSelection: selectionSetter,
            pick: { [weak self] idx in self?.pick(idx) }
        )
        let hosting = NSHostingView(rootView: view)
        hosting.autoresizingMask = [.width, .height]
        contentView = hosting

        centerOnActiveScreen()
        installKeyMonitor()
        // makeKey so keyboard events flow into this window (and our local
        // NSEvent monitor sees them). AppDelegate activates our app just
        // before calling show() — required because .nonactivatingPanel
        // alone won't route keys to us when the user was in another app.
        makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        uninstallKeyMonitor()
        orderOut(nil)
    }

    // MARK: - Selection / keyboard handling

    private func pick(_ index: Int) {
        guard index >= 0, index < itemCount else { return }
        uninstallKeyMonitor()
        orderOut(nil)
        onSelect(index)
    }

    private func cancel() {
        uninstallKeyMonitor()
        orderOut(nil)
        onCancel()
    }

    private func installKeyMonitor() {
        uninstallKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKey(event)
        }
        // Also trap click-outside via NSEvent.addGlobalMonitor for mouse-down,
        // so users can dismiss by clicking away. The panel's .transient
        // collectionBehavior hides it on Space/app-switch automatically, but
        // doesn't cover click-outside.
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            Task { @MainActor in self?.cancel() }
        }
    }

    private var globalMouseMonitor: Any?

    private func uninstallKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        if let m = globalMouseMonitor { NSEvent.removeMonitor(m); globalMouseMonitor = nil }
    }

    /// Returns `nil` (event consumed) for our keys; falls through otherwise.
    private func handleKey(_ event: NSEvent) -> NSEvent? {
        // keyCode constants: 126 up, 125 down, 36 return, 76 keypad-return, 53 esc
        switch event.keyCode {
        case 125:  // down
            let next = min(selectedIndex + 1, itemCount - 1)
            setSelection(next)
            contentView?.needsDisplay = true
            return nil
        case 126:  // up
            let next = max(selectedIndex - 1, 0)
            setSelection(next)
            contentView?.needsDisplay = true
            return nil
        case 36, 76:  // return / keypad enter
            pick(selectedIndex)
            return nil
        case 53:  // esc
            cancel()
            return nil
        default:
            // Digits 1-9 pick by number
            if let chars = event.charactersIgnoringModifiers,
               let d = Int(chars), d >= 1, d <= itemCount {
                pick(d - 1)
                return nil
            }
            return event
        }
    }

    private func centerOnActiveScreen() {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }
        let origin = NSPoint(
            x: visible.midX - frame.width / 2,
            y: visible.midY - frame.height / 2 + 80  // slightly above center
        )
        setFrameOrigin(origin)
    }
}

// MARK: - SwiftUI view

/// Panel content — a tight list of `BucketItem` rows keyed by index, with
/// an external selection channel so the NSPanel's keyboard monitor can drive
/// the highlight without the view owning state that outlives the panel.
@MainActor
struct QuickPasteView: View {
    let items: [BucketItem]
    let sidecarRoot: URL
    let getSelection: () -> Int
    let setSelection: (Int) -> Void
    let pick: (Int) -> Void

    @State private var selected: Int = 0
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "tray.and.arrow.up.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("Quick Paste")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("↑↓ pick · ⏎ paste · esc")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            Divider().opacity(0.3)

            if items.isEmpty {
                Text("Bucket is empty")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.offset) { pair in
                        QuickPasteRow(
                            index: pair.offset,
                            item: pair.element,
                            sidecarRoot: sidecarRoot,
                            isSelected: selected == pair.offset
                        )
                        .contentShape(Rectangle())
                        .onTapGesture { pick(pair.offset) }
                        .onHover { hovering in
                            if hovering {
                                selected = pair.offset
                                setSelection(pair.offset)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .frame(minWidth: 360, idealWidth: 360, maxWidth: 420, minHeight: 80)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(colorScheme == .dark
                        ? Color.white.opacity(0.12)
                        : Color.black.opacity(0.1),
                        lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onAppear { selected = getSelection() }
        // Poll the external selection ~30 fps — NSEvent monitor updates the
        // mutable state and we reflect it here. A proper @Observable wrapper
        // would be cleaner; polling is good enough for a transient popup.
        .onReceive(Timer.publish(every: 0.033, on: .main, in: .common).autoconnect()) { _ in
            let s = getSelection()
            if s != selected { selected = s }
        }
    }
}

/// One item row — displays kind icon, primary text, and a bucket-origin hint.
struct QuickPasteRow: View {
    let index: Int
    let item: BucketItem
    let sidecarRoot: URL
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            // Number / shortcut hint
            Text("\(index + 1)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 14, alignment: .trailing)

            // Kind icon
            Image(systemName: iconName)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 14)

            // Preview
            Text(previewText)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.primary)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            isSelected
            ? AnyShapeStyle(Color.accentColor.opacity(0.18))
            : AnyShapeStyle(Color.clear)
        )
    }

    private var iconName: String {
        switch item.kind {
        case .text, .richText: return "text.alignleft"
        case .url:             return "link"
        case .color:           return "paintpalette"
        case .file:            return "doc"
        case .folder:          return "folder"
        case .image:           return "photo"
        }
    }

    private var previewText: String {
        switch item.kind {
        case .text, .richText:
            let s = (item.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return s.isEmpty ? "(empty text)" : s
        case .url:
            return item.urlMeta?.urlString ?? "(url)"
        case .color:
            return item.colorHex ?? "(color)"
        case .file, .folder, .image:
            return item.fileRef?.displayName ?? item.fileRef?.originalPath ?? "(file)"
        }
    }
}
