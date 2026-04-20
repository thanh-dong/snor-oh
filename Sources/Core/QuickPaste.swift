import Foundation
import AppKit
import Carbon.HIToolbox
import ApplicationServices

/// Pasteboard + synth-paste helpers for the ⌘⇧V quick-paste popup.
///
/// Flow: (1) user picks an item in the popup → (2) `copyItemToPasteboard`
/// writes the right pasteboard representation for the item's kind →
/// (3) panel closes → (4) `synthesizeCommandV` posts a ⌘V to whatever app
/// is frontmost (the one the user was in before the popup appeared — since
/// our panel is non-activating, focus never left that app).
///
/// Accessibility permission is required for step 4. When not granted, the
/// helper gracefully degrades: content is still on the pasteboard, user
/// presses ⌘V themselves.
enum QuickPaster {

    // MARK: - Pasteboard

    /// Writes the best pasteboard representation for `item`. Returns `true`
    /// when the pasteboard was populated in at least one format. `sidecarRoot`
    /// is the parent of the `<bucket-id>/files|images/...` tree — needed to
    /// resolve images/files stored as relative paths.
    @discardableResult
    static func copyItemToPasteboard(_ item: BucketItem, sidecarRoot: URL) -> Bool {
        let pb = NSPasteboard.general
        pb.clearContents()

        switch item.kind {
        case .text:
            return pb.setString(item.text ?? "", forType: .string)

        case .richText:
            // Rich text is stored base64-encoded RTF in `item.text`. Write
            // the RTF blob AND a plain-text fallback so apps that don't
            // understand RTF still receive the textual payload.
            guard let b64 = item.text, let rtf = Data(base64Encoded: b64) else {
                return pb.setString(item.text ?? "", forType: .string)
            }
            _ = pb.setData(rtf, forType: .rtf)
            if let attr = NSAttributedString(rtf: rtf, documentAttributes: nil) {
                pb.setString(attr.string, forType: .string)
            }
            return true

        case .url:
            let s = item.urlMeta?.urlString ?? ""
            _ = pb.setString(s, forType: .string)
            if let url = URL(string: s) {
                _ = pb.writeObjects([url as NSURL])
            }
            return true

        case .color:
            return pb.setString(item.colorHex ?? "", forType: .string)

        case .file, .folder:
            // Prefer originalPath so the file reference survives even if our
            // sidecar copy has been evicted. Fall back to the sidecar; last
            // resort is pasting the path string as text.
            if let p = item.fileRef?.originalPath, !p.isEmpty,
               FileManager.default.fileExists(atPath: p) {
                _ = pb.writeObjects([URL(fileURLWithPath: p) as NSURL])
                return true
            }
            if let cached = item.fileRef?.cachedPath, !cached.isEmpty {
                let full = sidecarRoot.appendingPathComponent(cached)
                if FileManager.default.fileExists(atPath: full.path) {
                    _ = pb.writeObjects([full as NSURL])
                    return true
                }
            }
            let fallback = item.fileRef?.originalPath ?? item.fileRef?.cachedPath ?? ""
            return pb.setString(fallback, forType: .string)

        case .image:
            guard let cached = item.fileRef?.cachedPath, !cached.isEmpty else {
                return false
            }
            let full = sidecarRoot.appendingPathComponent(cached)
            if let img = NSImage(contentsOfFile: full.path) {
                _ = pb.writeObjects([img])
                return true
            }
            return false
        }
    }

    // MARK: - Synth paste

    /// Posts a ⌘V key-down + key-up to whichever app is frontmost. Async with
    /// a short delay so the calling panel has time to close first — otherwise
    /// the paste could be swallowed by us if we were somehow frontmost.
    ///
    /// No-op when Accessibility permission isn't granted — the pasteboard is
    /// still populated, so user pressing ⌘V manually works.
    static func synthesizeCommandV(delayMs: UInt64 = 60) {
        guard isAccessibilityTrusted(prompt: false) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(delayMs))) {
            let vKey: CGKeyCode = CGKeyCode(kVK_ANSI_V)
            let source = CGEventSource(stateID: .hidSystemState)
            let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
            let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
            down?.flags = .maskCommand
            up?.flags = .maskCommand
            down?.post(tap: .cgAnnotatedSessionEventTap)
            up?.post(tap: .cgAnnotatedSessionEventTap)
        }
    }

    /// Returns `true` iff this process is in the Accessibility allowlist.
    /// Pass `prompt: true` once — only on user-initiated flows — to trigger
    /// the system "add snor-oh to Accessibility" dialog.
    @discardableResult
    static func isAccessibilityTrusted(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options: CFDictionary = [key: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}

// MARK: - Item selection

extension BucketManager {
    /// Newest-first flat list across all non-archived buckets, capped at
    /// `limit`. Source for the ⌘⇧V popup. Sort key is `lastAccessedAt` so a
    /// promoted (re-copied) item bubbles to the top even if it was first
    /// added days ago.
    func latestItemsAcrossActiveBuckets(limit: Int) -> [BucketItem] {
        guard limit > 0 else { return [] }
        let pool = buckets.filter { !$0.archived }.flatMap { $0.items }
        return Array(pool.sorted { $0.lastAccessedAt > $1.lastAccessedAt }.prefix(limit))
    }
}
