import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Renders a single `BucketItem` as a compact card inside the bucket grid.
///
/// Per-kind visuals:
///   - `.file` / `.folder`: icon + name + size
///   - `.image`: thumbnail + kind chip
///   - `.url`: favicon + title + host
///   - `.text` / `.richText`: truncated text excerpt
///   - `.color`: swatch + hex string
///
/// Interactions:
///   - Hover reveals pin + delete buttons.
///   - Click pins (toggle).
///   - Drag-out provides an `NSItemProvider` of the right type (file URL / URL /
///     plain text / image / RTF).
///   - Right-click menu: Pin/Unpin, Copy as plain text, Remove.
struct BucketCardView: View {

    let item: BucketItem
    let storeRootURL: URL
    let manager: BucketManager

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            thumbnail
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 2) {
                Text(primaryLine)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                if let sub = secondaryLine {
                    Text(sub)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            if hovering {
                HStack(spacing: 4) {
                    Button {
                        manager.togglePin(id: item.id)
                    } label: {
                        Image(systemName: item.pinned ? "pin.fill" : "pin")
                            .font(.system(size: 10))
                            .foregroundStyle(item.pinned ? .orange : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help(item.pinned ? "Unpin" : "Pin")

                    Button {
                        manager.remove(id: item.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove")
                }
            } else if item.pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange.opacity(0.7))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(hovering ? Color.primary.opacity(0.08) : Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
        .onHover { hovering = $0 }
        .onDrag {
            itemProviderForDrag()
        }
        .contextMenu { contextMenu }
        .focusable()
        .onKeyPress(.space) {
            if let url = quickLookURL() {
                QuickLookPreviewer.shared.show(url: url)
                return .handled
            }
            return .ignored
        }
    }

    /// URL a Quick Look panel can display for this item. Only files and cached
    /// images qualify — text / URL / color items return nil (spacebar becomes
    /// a no-op).
    private func quickLookURL() -> URL? {
        switch item.kind {
        case .file, .folder:
            if let path = item.fileRef?.originalPath,
               !path.isEmpty,
               FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
            }
            if let rel = item.fileRef?.cachedPath {
                return storeRootURL.appendingPathComponent(rel)
            }
            return nil
        case .image:
            if let rel = item.fileRef?.cachedPath {
                return storeRootURL.appendingPathComponent(rel)
            }
            return nil
        case .url, .text, .richText, .color:
            return nil
        }
    }

    // MARK: - Context menu

    @ViewBuilder
    private var contextMenu: some View {
        Button(item.pinned ? "Unpin" : "Pin") {
            manager.togglePin(id: item.id)
        }
        if let plain = plainTextPayload {
            Button("Copy as Plain Text") {
                ClipboardMonitor.shared.suppressNextCapture = true
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(plain, forType: .string)
            }
        }
        if let url = item.urlMeta?.urlString, let _ = URL(string: url) {
            Button("Open URL") {
                if let u = URL(string: url) { NSWorkspace.shared.open(u) }
            }
        }
        if item.kind == .file || item.kind == .folder,
           let path = item.fileRef?.originalPath, !path.isEmpty {
            Button("Reveal in Finder") {
                NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
            }
        }
        Divider()
        Button("Remove") { manager.remove(id: item.id) }
    }

    // MARK: - Drag-out provider
    //
    // Every case below must produce a provider the destination app can
    // actually consume, so the drag-drop becomes an effective cross-app
    // "copy + paste":
    //   - Finder / any file-accepting drop target receives a file URL.
    //   - Browsers receive a web URL.
    //   - Text fields (TextEdit, Mail, Slack, etc.) receive plain text —
    //     even for RTF items, via a secondary plain-text representation.

    private func itemProviderForDrag() -> NSItemProvider {
        switch item.kind {
        case .file, .folder, .image:
            guard let url = fileURLForDrag() else { return NSItemProvider() }
            let provider = NSItemProvider(object: url as NSURL)
            if let name = item.fileRef?.displayName, !name.isEmpty {
                provider.suggestedName = name
            }
            return provider

        case .url:
            guard let s = item.urlMeta?.urlString, let url = URL(string: s) else {
                return NSItemProvider()
            }
            let provider = NSItemProvider(object: url as NSURL)
            if let title = item.urlMeta?.title, !title.isEmpty {
                provider.suggestedName = title
            }
            return provider

        case .text:
            return NSItemProvider(object: (item.text ?? "") as NSString)

        case .richText:
            let provider = NSItemProvider()
            guard let s = item.text, let rtf = Data(base64Encoded: s) else {
                return NSItemProvider(object: (item.text ?? "") as NSString)
            }
            provider.registerDataRepresentation(
                forTypeIdentifier: UTType.rtf.identifier, visibility: .all
            ) { completion in
                completion(rtf, nil)
                return nil
            }
            // Secondary plain-text rep so destinations that don't accept RTF
            // (URL bars, terminal, IM apps) still get the insertable text.
            if let attr = try? NSAttributedString(
                data: rtf,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil
            ) {
                let plain = attr.string
                provider.registerDataRepresentation(
                    forTypeIdentifier: UTType.utf8PlainText.identifier,
                    visibility: .all
                ) { completion in
                    completion(Data(plain.utf8), nil)
                    return nil
                }
            }
            return provider

        case .color:
            return NSItemProvider(object: (item.colorHex ?? "") as NSString)
        }
    }

    /// Resolve the best file URL for a drag-out. Prefers the original file
    /// (so Finder names the copy like the original), falling back to the
    /// bucket's sidecar so the drag still works after the original is moved
    /// or deleted — *or* when the item was captured via clipboard and never
    /// had an `originalPath` in the first place.
    private func fileURLForDrag() -> URL? {
        if let original = item.fileRef?.originalPath,
           !original.isEmpty,
           FileManager.default.fileExists(atPath: original) {
            return URL(fileURLWithPath: original)
        }
        if let cached = item.fileRef?.cachedPath {
            let absolute = storeRootURL.appendingPathComponent(cached)
            if FileManager.default.fileExists(atPath: absolute.path) {
                return absolute
            }
        }
        return nil
    }

    // MARK: - Thumbnail

    @ViewBuilder
    private var thumbnail: some View {
        switch item.kind {
        case .image:
            if let rel = item.fileRef?.cachedPath,
               let nsImage = NSImage(contentsOf: storeRootURL.appendingPathComponent(rel)) {
                Image(nsImage: nsImage).resizable().scaledToFill()
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        case .file:
            fileIconView
        case .folder:
            Image(systemName: "folder.fill")
                .font(.system(size: 22))
                .foregroundStyle(.blue)
        case .url:
            Image(systemName: "link")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
        case .text, .richText:
            Image(systemName: "text.alignleft")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
        case .color:
            let hex = item.colorHex ?? "#999999"
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(hex: hex) ?? .gray)
                .frame(width: 28, height: 28)
        }
    }

    @ViewBuilder
    private var fileIconView: some View {
        if let path = item.fileRef?.originalPath, !path.isEmpty,
           FileManager.default.fileExists(atPath: path) {
            let icon = NSWorkspace.shared.icon(forFile: path)
            Image(nsImage: icon).resizable().scaledToFit()
        } else {
            Image(systemName: "doc")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Text content

    private var primaryLine: String {
        switch item.kind {
        case .file, .folder, .image:
            return item.fileRef?.displayName ?? "Untitled"
        case .url:
            return item.urlMeta?.title ?? item.urlMeta?.urlString ?? "Link"
        case .text, .richText:
            let s = plainTextPayload ?? ""
            return s.split(separator: "\n").first.map(String.init) ?? s
        case .color:
            return item.colorHex ?? "#000000"
        }
    }

    private var secondaryLine: String? {
        switch item.kind {
        case .file, .image:
            return item.fileRef.flatMap { formatSize($0.byteSize) }
        case .folder:
            return "Folder"
        case .url:
            if let host = item.urlMeta.flatMap({ URL(string: $0.urlString)?.host }) { return host }
            return item.urlMeta?.urlString
        case .text:
            let count = (plainTextPayload ?? "").count
            return "\(count) chars"
        case .richText:
            return "Rich text"
        case .color:
            return nil
        }
    }

    private var plainTextPayload: String? {
        switch item.kind {
        case .text:
            return item.text
        case .richText:
            // RTF → plain text for display / copy-out
            if let s = item.text, let data = Data(base64Encoded: s),
               let attr = try? NSAttributedString(
                   data: data,
                   options: [.documentType: NSAttributedString.DocumentType.rtf],
                   documentAttributes: nil
               ) {
                return attr.string
            }
            return item.text
        default:
            return nil
        }
    }

    private func formatSize(_ bytes: Int64) -> String {
        let fmt = ByteCountFormatter()
        fmt.allowedUnits = [.useKB, .useMB, .useGB]
        fmt.countStyle = .file
        return fmt.string(fromByteCount: bytes)
    }
}

// MARK: - Color(hex:) helper

extension Color {
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8,
              let v = UInt64(s, radix: 16) else { return nil }
        let r, g, b, a: Double
        if s.count == 8 {
            a = Double((v >> 24) & 0xFF) / 255.0
            r = Double((v >> 16) & 0xFF) / 255.0
            g = Double((v >> 8) & 0xFF) / 255.0
            b = Double(v & 0xFF) / 255.0
        } else {
            a = 1.0
            r = Double((v >> 16) & 0xFF) / 255.0
            g = Double((v >> 8) & 0xFF) / 255.0
            b = Double(v & 0xFF) / 255.0
        }
        self = Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}
