import Foundation
import AppKit

/// Polls `NSPasteboard.general.changeCount` every 500 ms and feeds new
/// text / URL copies into `BucketManager.shared`.
///
/// Scoped to **text, URLs, and colors** in v1. File and image clipboard
/// captures are out of scope here — Epic 03 owns screenshot auto-catch;
/// file drag-in already works via `BucketDropHandler`.
///
/// Respects `BucketSettings.ignoredBundleIDs` — if the frontmost app's bundle
/// ID is ignored, the capture is skipped.
///
/// Uses the CLAUDE.md-mandated timer pattern:
/// `Timer(timeInterval:...)` + `RunLoop.main.add(t, forMode: .common)`.
@MainActor
final class ClipboardMonitor {

    static let shared = ClipboardMonitor()

    private var timer: Timer?
    private var lastChangeCount: Int = -1
    private let pasteboard: NSPasteboard = .general

    /// Set this to `true` immediately before the app writes to the pasteboard
    /// (e.g. "Copy as Plain Text" from a bucket card context menu). The next
    /// tick will swallow the change, preventing a self-capture feedback loop.
    var suppressNextCapture: Bool = false

    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard timer == nil else { return }
        // Seed: skip whatever's currently on the clipboard.
        lastChangeCount = pasteboard.changeCount

        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Tick

    private func tick() {
        let manager = BucketManager.shared
        guard manager.settings.captureClipboard else { return }

        let current = pasteboard.changeCount
        guard current != lastChangeCount else { return }
        lastChangeCount = current

        // Swallow writes we made ourselves (e.g. "Copy as Plain Text" in the
        // bucket card context menu) — prevents a duplicate-capture loop.
        if suppressNextCapture {
            suppressNextCapture = false
            return
        }

        // Ignore list via frontmost app bundle ID.
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if let frontmost, manager.settings.ignoredBundleIDs.contains(frontmost) {
            return
        }

        guard let item = extractItem(sourceBundleID: frontmost) else { return }
        manager.add(item, source: .clipboard)
    }

    // MARK: - Pasteboard → BucketItem

    private func extractItem(sourceBundleID: String?) -> BucketItem? {
        // Priority: URL > rich text (RTF) > plain text > color
        if let urlString = readURL() {
            return BucketItem(
                kind: .url,
                sourceBundleID: sourceBundleID,
                urlMeta: .init(urlString: urlString, title: nil)
            )
        }
        if let rtf = pasteboard.data(forType: .rtf) {
            return BucketItem(
                kind: .richText,
                sourceBundleID: sourceBundleID,
                text: rtf.base64EncodedString()
            )
        }
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            return BucketItem(
                kind: .text,
                sourceBundleID: sourceBundleID,
                text: text
            )
        }
        if let color = readColor() {
            return BucketItem(
                kind: .color,
                sourceBundleID: sourceBundleID,
                colorHex: color
            )
        }
        return nil
    }

    private func readURL() -> String? {
        // NSPasteboard.readObjects(forClasses: [NSURL.self])
        if let objs = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           let first = objs.first, !first.isFileURL {
            return first.absoluteString
        }
        return nil
    }

    private func readColor() -> String? {
        if let objs = pasteboard.readObjects(forClasses: [NSColor.self], options: nil) as? [NSColor],
           let color = objs.first {
            let rgb = color.usingColorSpace(.sRGB) ?? color
            let r = Int(round(rgb.redComponent * 255))
            let g = Int(round(rgb.greenComponent * 255))
            let b = Int(round(rgb.blueComponent * 255))
            return String(format: "#%02X%02X%02X", r, g, b)
        }
        return nil
    }
}
