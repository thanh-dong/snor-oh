import Foundation
import AppKit

/// Polls `NSPasteboard.general.changeCount` every 500 ms and feeds new
/// copies into `BucketManager.shared`.
///
/// Capture priority (highest first):
///   1. **File URL** — ⌘C on a file in Finder lands here. The file is
///      copied into the bucket's sidecar via `add(fileAt:)` so the bucket
///      item owns the bytes (not just the filename string).
///   2. **Image bytes** — e.g. ⌘C on a region in Preview. Written to the
///      sidecar via `add(imageData:)`.
///   3. **Web URL** (non-file URL).
///   4. **RTF** — stored as base64.
///   5. **Plain text**.
///   6. **NSColor** — serialized as #RRGGBB.
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

        // 1. File URLs (⌘C on files in Finder). Route through async
        //    `add(fileAt:)` so the file's bytes are actually copied into the
        //    bucket sidecar — not just the filename string.
        let fileURLs = readFileURLs()
        if !fileURLs.isEmpty {
            let groupID: UUID? = fileURLs.count > 1 ? UUID() : nil
            for url in fileURLs {
                Task { @MainActor in
                    await manager.add(fileAt: url, source: .clipboard, stackGroupID: groupID)
                }
            }
            return
        }

        // 2. Image bytes (⌘C on a region in Preview, screenshots going through
        //    the clipboard, etc.). Route through async `add(imageData:)`.
        if let imageData = readImageData() {
            Task { @MainActor in
                await manager.add(imageData: imageData, source: .clipboard)
            }
            return
        }

        // 3–6. Non-file items — synchronous path.
        guard let item = extractItem(sourceBundleID: frontmost) else { return }
        manager.add(item, source: .clipboard)
    }

    // MARK: - Pasteboard → BucketItem (non-file)

    private func extractItem(sourceBundleID: String?) -> BucketItem? {
        // Priority: web URL > RTF > plain text > color
        if let urlString = readWebURL() {
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

    // MARK: - Pasteboard readers

    /// File URLs (if any). Finder's ⌘C puts both a file URL and the file's
    /// display name on the pasteboard — grab the URL first so we capture the
    /// bytes, not the name.
    private func readFileURLs() -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        guard let objs = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: options
        ) as? [URL] else {
            return []
        }
        return objs.filter { $0.isFileURL }
    }

    /// Non-file web URL (http / https / etc.).
    private func readWebURL() -> String? {
        if let objs = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           let first = objs.first, !first.isFileURL {
            return first.absoluteString
        }
        return nil
    }

    /// Raw image bytes from the pasteboard (PNG preferred, TIFF fallback).
    /// Returns nil if the pasteboard is currently advertising a file URL —
    /// that case is handled by `readFileURLs()` to preserve the original
    /// file on disk + extension.
    private func readImageData() -> Data? {
        let types = pasteboard.types ?? []
        // Skip if a file URL is present — file path wins.
        if types.contains(.fileURL) { return nil }

        // Prefer PNG; fall back to TIFF → PNG conversion.
        if types.contains(.png), let data = pasteboard.data(forType: .png) {
            return data
        }
        if types.contains(.tiff), let tiff = pasteboard.data(forType: .tiff) {
            if let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                return png
            }
            return tiff
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
