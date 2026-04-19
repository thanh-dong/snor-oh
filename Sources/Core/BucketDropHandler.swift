import Foundation
import AppKit
import UniformTypeIdentifiers

/// Unpacks `NSItemProvider`s coming from SwiftUI `.onDrop(of:...)` into
/// `BucketItem`s and adds them to `BucketManager.shared`.
///
/// Priority (highest first): file URL > image bytes > web URL > rich text > plain text.
/// A single drop of N providers becomes N items sharing a `stackGroupID` if N > 1.
@MainActor
enum BucketDropHandler {

    /// UTTypes offered to SwiftUI's `.onDrop(of:)` matcher. Keep aligned with
    /// the `ingest(providers:source:)` switch below.
    static let supportedUTTypes: [UTType] = [
        .fileURL,
        .image,
        .url,
        .rtf,
        .utf8PlainText,
        .plainText,
    ]

    /// Entry point called from `.onDrop(of:supportedUTTypes)` closures.
    /// Returns `true` synchronously so SwiftUI accepts the drop; real work
    /// happens asynchronously as providers resolve (and, for files/images,
    /// as sidecar copies complete).
    @discardableResult
    static func ingest(providers: [NSItemProvider], source: BucketChangeSource) -> Bool {
        guard !providers.isEmpty else { return false }
        let groupID: UUID? = providers.count > 1 ? UUID() : nil

        for provider in providers {
            Task { @MainActor in
                await resolveAndInsert(from: provider, source: source, stackGroupID: groupID)
            }
        }
        return true
    }

    // MARK: - Provider resolution + insertion

    private static func resolveAndInsert(
        from provider: NSItemProvider,
        source: BucketChangeSource,
        stackGroupID: UUID?
    ) async {
        let manager = BucketManager.shared

        // 1. File URL (files + folders) — routes through `add(fileAt:)` which
        //    copies the sidecar before insert.
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            if let url = await loadFileURL(from: provider) {
                await manager.add(fileAt: url, source: source, stackGroupID: stackGroupID)
                return
            }
        }

        // 2. Image bytes — writes sidecar PNG, then inserts.
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            if let data = await loadData(from: provider, type: UTType.image.identifier) {
                await manager.add(imageData: data, source: source, stackGroupID: stackGroupID)
                return
            }
        }

        // 3. Web URL (not file URL) — no sidecar needed.
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            if let url = await loadURL(from: provider), !url.isFileURL {
                let item = BucketItem(
                    kind: .url,
                    stackGroupID: stackGroupID,
                    urlMeta: .init(urlString: url.absoluteString, title: nil)
                )
                manager.add(item, source: source)
                return
            }
        }

        // 4. Rich text (RTF) — stored inline (base64 in `text`).
        if provider.hasItemConformingToTypeIdentifier(UTType.rtf.identifier) {
            if let data = await loadData(from: provider, type: UTType.rtf.identifier) {
                let item = BucketItem(
                    kind: .richText,
                    stackGroupID: stackGroupID,
                    text: data.base64EncodedString()
                )
                manager.add(item, source: source)
                return
            }
        }

        // 5. Plain text — stored inline.
        for id in [UTType.utf8PlainText.identifier, UTType.plainText.identifier] {
            if provider.hasItemConformingToTypeIdentifier(id) {
                if let s = await loadString(from: provider, type: id) {
                    let item = BucketItem(kind: .text, stackGroupID: stackGroupID, text: s)
                    manager.add(item, source: source)
                    return
                }
            }
        }
    }

    // MARK: - Async NSItemProvider loaders

    private static func loadFileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { cont in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    cont.resume(returning: url); return
                }
                if let url = item as? URL {
                    cont.resume(returning: url); return
                }
                cont.resume(returning: nil)
            }
        }
    }

    private static func loadURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { cont in
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                if let url = item as? URL {
                    cont.resume(returning: url); return
                }
                if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    cont.resume(returning: url); return
                }
                if let s = item as? String, let url = URL(string: s) {
                    cont.resume(returning: url); return
                }
                cont.resume(returning: nil)
            }
        }
    }

    private static func loadData(from provider: NSItemProvider, type: String) async -> Data? {
        await withCheckedContinuation { cont in
            provider.loadItem(forTypeIdentifier: type, options: nil) { item, _ in
                if let data = item as? Data {
                    cont.resume(returning: data); return
                }
                if let url = item as? URL, let data = try? Data(contentsOf: url) {
                    cont.resume(returning: data); return
                }
                cont.resume(returning: nil)
            }
        }
    }

    private static func loadString(from provider: NSItemProvider, type: String) async -> String? {
        await withCheckedContinuation { cont in
            provider.loadItem(forTypeIdentifier: type, options: nil) { item, _ in
                if let s = item as? String {
                    cont.resume(returning: s); return
                }
                if let data = item as? Data, let s = String(data: data, encoding: .utf8) {
                    cont.resume(returning: s); return
                }
                cont.resume(returning: nil)
            }
        }
    }
}
