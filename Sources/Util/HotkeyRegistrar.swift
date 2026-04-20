import Foundation
import Carbon.HIToolbox
import AppKit

/// Registers global hotkeys via Carbon `RegisterEventHotKey`.
///
/// Scope: a single bucket-toggle hotkey for Epic 01. Later epics (04, 06)
/// will register additional hotkeys through a new `register(id:binding:callback:)`
/// overload — kept as TODO below to avoid over-engineering.
@MainActor
final class HotkeyRegistrar {

    static let shared = HotkeyRegistrar()

    private var hotKeyRef: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var callback: (() -> Void)?

    /// Ref + callback for the quick-paste hotkey (id 2). Separate id so the
    /// event handler's existing demux-by-id pattern extends cleanly.
    private var quickPasteRef: EventHotKeyRef?
    private var quickPasteCallback: (() -> Void)?

    /// Refs for ⌃⌥1…⌃⌥9 bucket-switcher hotkeys (Phase 6). Index i holds the
    /// ref registered for N = i + 1 (id 1001…1009). Nil slots mean that
    /// particular Carbon registration failed.
    private var bucketSwitcherHotKeys: [EventHotKeyRef?] = []
    private var bucketSwitcherCallback: ((Int) -> Void)?

    /// Base ID range for bucket-switcher hotkeys. Keeps them disjoint from the
    /// bucket-toggle hotkey (id 1) so the single event handler can demux.
    private static let bucketSwitcherIDBase: UInt32 = 1000

    private init() {}

    // MARK: - Public

    /// Re-registers the hotkey. Safe to call repeatedly on settings change.
    /// No-op if the binding has no resolvable key code.
    func registerBucketToggle(binding: HotkeyBinding, callback: @escaping () -> Void) {
        unregister()
        guard let keyCode = Self.keyCode(for: binding.key) else {
            NSLog("[hotkey] unsupported key: \(binding.key)")
            return
        }
        let carbonMods = Self.carbonModifiers(from: binding.modifiers)

        installHandlerIfNeeded()

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(
            UInt32(keyCode),
            carbonMods,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else {
            NSLog("[hotkey] RegisterEventHotKey failed: \(status)")
            return
        }
        self.hotKeyRef = ref
        self.callback = callback
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        callback = nil
    }

    /// Re-registers the quick-paste hotkey (id 2). Same idempotent pattern
    /// as `registerBucketToggle` so settings-driven rebinds "just work".
    func registerQuickPaste(binding: HotkeyBinding, callback: @escaping () -> Void) {
        unregisterQuickPaste()
        guard let keyCode = Self.keyCode(for: binding.key) else {
            NSLog("[hotkey] quick-paste: unsupported key \(binding.key)")
            return
        }
        let carbonMods = Self.carbonModifiers(from: binding.modifiers)

        installHandlerIfNeeded()

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: 2)
        let status = RegisterEventHotKey(
            UInt32(keyCode),
            carbonMods,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else {
            NSLog("[hotkey] quick-paste RegisterEventHotKey failed: \(status)")
            return
        }
        self.quickPasteRef = ref
        self.quickPasteCallback = callback
    }

    func unregisterQuickPaste() {
        if let ref = quickPasteRef {
            UnregisterEventHotKey(ref)
            quickPasteRef = nil
        }
        quickPasteCallback = nil
    }

    /// Registers ⌃⌥1 through ⌃⌥9 as bucket-switcher hotkeys (Phase 6).
    /// The handler is invoked with N (1-based) on keypress. Callers should
    /// resolve N against their current visible-bucket list and no-op when
    /// N is out of range — no error is raised here.
    ///
    /// Safe to call repeatedly; earlier registrations are torn down first.
    func registerBucketSwitchers(handler: @escaping (Int) -> Void) {
        unregisterBucketSwitchers()
        installHandlerIfNeeded()

        let carbonMods = UInt32(controlKey) | UInt32(optionKey)
        let digitKeyCodes: [Int] = [
            kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3,
            kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6,
            kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9,
        ]

        var refs: [EventHotKeyRef?] = []
        for (i, keyCode) in digitKeyCodes.enumerated() {
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(
                signature: Self.signature,
                id: Self.bucketSwitcherIDBase + UInt32(i + 1)
            )
            let status = RegisterEventHotKey(
                UInt32(keyCode),
                carbonMods,
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &ref
            )
            if status != noErr {
                NSLog("[hotkey] bucket-switcher \(i + 1) RegisterEventHotKey failed: \(status)")
                refs.append(nil)
            } else {
                refs.append(ref)
            }
        }

        self.bucketSwitcherHotKeys = refs
        self.bucketSwitcherCallback = handler
    }

    func unregisterBucketSwitchers() {
        for ref in bucketSwitcherHotKeys {
            if let ref { UnregisterEventHotKey(ref) }
        }
        bucketSwitcherHotKeys.removeAll()
        bucketSwitcherCallback = nil
    }

    // MARK: - Private: event handler installation

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let userData = Unmanaged.passUnretained(self).toOpaque()
        let handlerProc: EventHandlerUPP = { _, eventRef, userData in
            guard let userData, let eventRef else { return noErr }
            let me = Unmanaged<HotkeyRegistrar>.fromOpaque(userData).takeUnretainedValue()

            // Read the hot-key ID from the event and verify it's ours.
            var hkID = EventHotKeyID()
            let gotID = GetEventParameter(
                eventRef,
                UInt32(kEventParamDirectObject),
                UInt32(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hkID
            )
            guard gotID == noErr, hkID.signature == HotkeyRegistrar.signature else {
                return noErr
            }

            let rawID = hkID.id
            DispatchQueue.main.async {
                if rawID == 1 {
                    me.callback?()
                } else if rawID == 2 {
                    me.quickPasteCallback?()
                } else if rawID > HotkeyRegistrar.bucketSwitcherIDBase
                    && rawID <= HotkeyRegistrar.bucketSwitcherIDBase + 9 {
                    let n = Int(rawID - HotkeyRegistrar.bucketSwitcherIDBase)
                    me.bucketSwitcherCallback?(n)
                }
            }
            return noErr
        }

        var outHandler: EventHandlerRef?
        InstallEventHandler(
            GetApplicationEventTarget(),
            handlerProc,
            1,
            &spec,
            userData,
            &outHandler
        )
        self.handler = outHandler
    }

    // MARK: - Private: key + modifier mapping

    private static let signature: OSType = {
        let chars = Array("SNOH".utf8)
        return (OSType(chars[0]) << 24)
            | (OSType(chars[1]) << 16)
            | (OSType(chars[2]) << 8)
            | OSType(chars[3])
    }()

    /// Minimal key-code table. Letters A–Z + digits 0–9 covers the full default
    /// bucket binding (⌃⌥B). Extend as needed if more keys become user-rebindable.
    private static let keyCodes: [String: Int] = [
        "A": kVK_ANSI_A, "B": kVK_ANSI_B, "C": kVK_ANSI_C, "D": kVK_ANSI_D,
        "E": kVK_ANSI_E, "F": kVK_ANSI_F, "G": kVK_ANSI_G, "H": kVK_ANSI_H,
        "I": kVK_ANSI_I, "J": kVK_ANSI_J, "K": kVK_ANSI_K, "L": kVK_ANSI_L,
        "M": kVK_ANSI_M, "N": kVK_ANSI_N, "O": kVK_ANSI_O, "P": kVK_ANSI_P,
        "Q": kVK_ANSI_Q, "R": kVK_ANSI_R, "S": kVK_ANSI_S, "T": kVK_ANSI_T,
        "U": kVK_ANSI_U, "V": kVK_ANSI_V, "W": kVK_ANSI_W, "X": kVK_ANSI_X,
        "Y": kVK_ANSI_Y, "Z": kVK_ANSI_Z,
        "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
        "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7,
        "8": kVK_ANSI_8, "9": kVK_ANSI_9,
    ]

    /// Pure static lookup — no main-actor state touched, so safe to expose
    /// `nonisolated` for the recorder's parse path (runs off-main via NSEvent).
    nonisolated static func keyCode(for key: String) -> Int? {
        keyCodes[key.uppercased()]
    }

    nonisolated static func carbonModifiers(from mods: Set<HotkeyBinding.Modifier>) -> UInt32 {
        var out: UInt32 = 0
        if mods.contains(.command) { out |= UInt32(cmdKey) }
        if mods.contains(.option)  { out |= UInt32(optionKey) }
        if mods.contains(.control) { out |= UInt32(controlKey) }
        if mods.contains(.shift)   { out |= UInt32(shiftKey) }
        return out
    }
}
