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
    /// Epic 07 — present a sheet for Translate (which can't live in a Menu
    /// because it needs a SwiftUI `.translationTask` modifier host view).
    @State private var showingTranslateSheet = false
    /// Epic 07 — card-focus tracker. Click the card → Space previews it.
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            thumbnail
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                // Epic 07 — derived-item provenance badge. For OCR'd text,
                // shows a tiny `text.viewfinder` bubble in the bottom-right
                // corner of the thumbnail so a glance at the card says
                // "this came from an image".
                .overlay(alignment: .bottomTrailing) {
                    if let symbol = derivedBadgeSymbol {
                        Image(systemName: symbol)
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 14, height: 14)
                            .background {
                                Circle().fill(derivedBadgeColor)
                            }
                            .overlay {
                                Circle().stroke(Color.white.opacity(0.85), lineWidth: 1)
                            }
                            .offset(x: 4, y: 4)
                            .help(derivedBadgeHelp ?? "")
                    }
                }

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
                .fill(backgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(
                    isFocused ? Color.accentColor : Color.primary.opacity(0.06),
                    lineWidth: isFocused ? 1.5 : 0.5
                )
        )
        // Epic 07 — spinner overlay when this item has an in-flight quick action.
        .overlay(alignment: .trailing) {
            if manager.processingItemIDs.contains(item.id) {
                ProgressView()
                    .controlSize(.small)
                    .padding(.trailing, 10)
                    .allowsHitTesting(false)
            }
        }
        .onHover { hovering = $0 }
        .onDrag {
            itemProviderForDrag()
        }
        .contextMenu { contextMenu }
        .sheet(isPresented: $showingTranslateSheet) {
            translateSheetContent
        }
        // Epic 07 — click anywhere on the card to select it. The hit test
        // covers the whole HStack because `.contentShape(.rect)` widens the
        // gesture target to include the background fill + transparent gaps.
        .contentShape(Rectangle())
        .onTapGesture {
            isFocused = true
        }
        .focusable()
        .focused($isFocused)
        .onKeyPress(.space) {
            if let url = quickLookURL() {
                QuickLookPreviewer.shared.show(url: url)
                return .handled
            }
            return .ignored
        }
    }

    /// Background tint reflects hover + focus independently so both states
    /// can compose. Focused wins (subtle accent overlay).
    private var backgroundColor: Color {
        if isFocused {
            return Color.accentColor.opacity(0.14)
        }
        if hovering {
            return Color.primary.opacity(0.08)
        }
        return Color.primary.opacity(0.04)
    }

    /// URL a Quick Look panel can display for this item. Every item kind is
    /// supported by materializing its payload into a temp file when there
    /// isn't already a file on disk to preview:
    ///
    ///   - `.file` / `.folder` / `.image`: existing cached / original path.
    ///   - `.text`: writes `<item-id>.txt` to `NSTemporaryDirectory`.
    ///   - `.richText`: writes the decoded RTF as `<item-id>.rtf`.
    ///   - `.url`: writes a `.webloc` plist so Quick Look renders the link
    ///     with title + favicon handled by the system.
    ///   - `.color`: writes a 128×128 PNG swatch plus the hex code.
    ///
    /// The temp files are stable (keyed by item UUID) so the preview panel
    /// can use `reloadData()` without chasing a fresh URL each time.
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
        case .text:
            guard let body = item.text, !body.isEmpty else { return nil }
            return Self.materializeTempPreview(
                id: item.id,
                ext: "txt",
                data: Data(body.utf8)
            )
        case .richText:
            // RTF arrives base64-encoded in `item.text`. Decode → write
            // `.rtf` so Quick Look renders with formatting.
            if let encoded = item.text, let rtfData = Data(base64Encoded: encoded) {
                return Self.materializeTempPreview(
                    id: item.id,
                    ext: "rtf",
                    data: rtfData
                )
            }
            // Fallback: treat it as plain text.
            if let encoded = item.text {
                return Self.materializeTempPreview(
                    id: item.id,
                    ext: "txt",
                    data: Data(encoded.utf8)
                )
            }
            return nil
        case .url:
            guard let s = item.urlMeta?.urlString, !s.isEmpty else { return nil }
            let title = item.urlMeta?.title ?? s
            let webloc = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
                <key>URL</key><string>\(s)</string>
                <key>Title</key><string>\(title)</string>
            </dict></plist>
            """
            return Self.materializeTempPreview(
                id: item.id,
                ext: "webloc",
                data: Data(webloc.utf8)
            )
        case .color:
            guard let hex = item.colorHex else { return nil }
            guard let data = Self.renderColorSwatchPNG(hex: hex) else { return nil }
            return Self.materializeTempPreview(
                id: item.id,
                ext: "png",
                data: data
            )
        }
    }

    /// Writes `data` under `NSTemporaryDirectory()/snor-oh-preview/<id>.<ext>`
    /// and returns the URL. Idempotent — same (id, ext) reuses the same path,
    /// overwriting contents. Cleanup happens at app termination (the temp
    /// directory is purged by the OS).
    private static func materializeTempPreview(
        id: UUID,
        ext: String,
        data: Data
    ) -> URL? {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("snor-oh-preview", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        let url = dir.appendingPathComponent("\(id.uuidString).\(ext)")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// Small PNG swatch for `.color` items. 128×128 filled with the hex
    /// colour, white border. Pure ImageIO — no NSImage round-trip.
    private static func renderColorSwatchPNG(hex: String) -> Data? {
        guard let cgFill = hexToCGColor(hex) else { return nil }
        let size = 128
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo: UInt32 = CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder32Big.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: size, height: size,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }

        ctx.setFillColor(cgFill)
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        ctx.setStrokeColor(CGColor(gray: 1.0, alpha: 1.0))
        ctx.setLineWidth(4)
        ctx.stroke(CGRect(x: 2, y: 2, width: size - 4, height: size - 4))

        guard let cg = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            out, "public.png" as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    /// Parses `#RRGGBB` / `RRGGBB` / `#RRGGBBAA` into a sRGB CGColor.
    /// Duplicates the Color(hex:) logic but returns a CGColor suitable for
    /// CGContext — SwiftUI's `Color` doesn't expose a stable cgColor outside
    /// a rendering pass, which is unreliable from a static helper.
    private static func hexToCGColor(_ hex: String) -> CGColor? {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8,
              let v = UInt64(s, radix: 16) else { return nil }
        let r, g, b, a: CGFloat
        if s.count == 8 {
            a = CGFloat((v >> 24) & 0xFF) / 255.0
            r = CGFloat((v >> 16) & 0xFF) / 255.0
            g = CGFloat((v >> 8) & 0xFF) / 255.0
            b = CGFloat(v & 0xFF) / 255.0
        } else {
            a = 1.0
            r = CGFloat((v >> 16) & 0xFF) / 255.0
            g = CGFloat((v >> 8) & 0xFF) / 255.0
            b = CGFloat(v & 0xFF) / 255.0
        }
        return CGColor(
            colorSpace: CGColorSpaceCreateDeviceRGB(),
            components: [r, g, b, a]
        )
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

        // Epic 07 — Actions submenu. Populated from QuickActionRegistry,
        // filtered to actions that apply to this item. Each action dispatches
        // to a BucketActionRunner helper that handles params + insertion.
        let applicable = QuickActionRegistry.actionsApplying(to: [item])
        if !applicable.isEmpty || translateAvailable {
            Menu("Actions") {
                ForEach(applicable.map { AnyActionType(type: $0) }) { entry in
                    actionSubmenu(for: entry.type)
                }
                if translateAvailable {
                    Divider()
                    Button("Translate to…") {
                        showingTranslateSheet = true
                    }
                }
            }
        }

        // Epic 07 — jump back to the item this one was derived from. Only
        // shown when the source is still around.
        if let sourceID = item.derivedFromItemID,
           manager.findItem(id: sourceID) != nil {
            Button("Reveal Source") {
                NotificationCenter.default.post(
                    name: .bucketRevealItem,
                    object: nil,
                    userInfo: ["itemID": sourceID]
                )
            }
        }

        let destinations = manager.activeBuckets.filter { $0.id != manager.activeBucketID }
        if !destinations.isEmpty {
            Menu("Move to") {
                ForEach(destinations, id: \.id) { b in
                    Button {
                        manager.moveItem(item.id, toBucket: b.id)
                    } label: {
                        Text(b.emoji.map { "\($0)  \(b.name)" } ?? b.name)
                    }
                }
            }
        }

        Divider()
        Button("Remove") { manager.remove(id: item.id) }
    }

    // MARK: - Action menu helpers

    /// Whether to surface the Translate entry. Gated on OS version AND on
    /// whether we have something translatable (plain text, rich text, or an
    /// image that has already been OCR'd).
    private var translateAvailable: Bool {
        guard #available(macOS 15.0, *) else { return false }
        return translateSourceText != nil
    }

    /// The string we'd hand the translator — `item.text` for text items,
    /// the RTF-rendered plain text for richText, and `ocrText` for images.
    /// Returns nil when there's nothing to translate yet (e.g. image not OCR'd).
    private var translateSourceText: String? {
        switch item.kind {
        case .text:
            return item.text
        case .richText:
            return plainTextPayload
        case .image:
            let t = item.ocrText?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (t?.isEmpty == false) ? t : nil
        default:
            return nil
        }
    }

    @ViewBuilder
    private var translateSheetContent: some View {
        if #available(macOS 15.0, *), let sourceText = translateSourceText {
            TranslateSheet(
                sourceText: sourceText,
                sourceItemID: item.id,
                bucketID: manager.bucketID(forItemID: item.id) ?? manager.activeBucketID,
                onFinished: { showingTranslateSheet = false }
            )
        } else {
            VStack(spacing: 12) {
                Text("Translation requires macOS 15.0 or later.")
                Button("Close") { showingTranslateSheet = false }
            }
            .padding(20)
        }
    }

    /// Dispatch per action-type. For actions with variant parameters (resize
    /// 50%/25%, convert png/jpeg/heic), we render a submenu; single-shot
    /// actions render as a flat Button. All invocations funnel through
    /// `BucketActionRunner.run` so the UI stays thin.
    @ViewBuilder
    private func actionSubmenu(for type: any QuickAction.Type) -> some View {
        switch type.id {
        case ResizeImageAction.id:
            Menu("Resize image") {
                Button("50%") { runResize(0.5) }
                Button("25%") { runResize(0.25) }
                Button("10%") { runResize(0.10) }
            }
        case ConvertImageAction.id:
            Menu("Convert to") {
                Button("PNG")  { runConvert("png") }
                Button("JPEG") { runConvert("jpeg") }
                Button("HEIC") { runConvert("heic") }
            }
        case StripExifAction.id:
            Button("Strip metadata") { runStrip() }
        case ExtractTextAction.id:
            Button("Extract text") { runExtract() }
        default:
            Button(type.title) {
                runSimple(type)
            }
        }
    }

    private func runResize(_ scale: Double) {
        var ctx = ActionContext(
            storeRootURL: storeRootURL,
            store: manager.store,
            destinationBucketID: manager.bucketID(forItemID: item.id) ?? manager.activeBucketID
        )
        ctx.params["scale"] = String(scale)
        BucketActionRunner.run(ResizeImageAction.self, items: [item], context: ctx, manager: manager)
    }

    private func runConvert(_ format: String) {
        var ctx = ActionContext(
            storeRootURL: storeRootURL,
            store: manager.store,
            destinationBucketID: manager.bucketID(forItemID: item.id) ?? manager.activeBucketID
        )
        ctx.params["format"] = format
        BucketActionRunner.run(ConvertImageAction.self, items: [item], context: ctx, manager: manager)
    }

    private func runStrip() {
        let ctx = ActionContext(
            storeRootURL: storeRootURL,
            store: manager.store,
            destinationBucketID: manager.bucketID(forItemID: item.id) ?? manager.activeBucketID
        )
        BucketActionRunner.run(StripExifAction.self, items: [item], context: ctx, manager: manager)
    }

    private func runExtract() {
        let ctx = ActionContext(
            storeRootURL: storeRootURL,
            store: manager.store,
            destinationBucketID: manager.bucketID(forItemID: item.id) ?? manager.activeBucketID
        )
        BucketActionRunner.run(ExtractTextAction.self, items: [item], context: ctx, manager: manager)
    }

    private func runSimple(_ type: any QuickAction.Type) {
        let ctx = ActionContext(
            storeRootURL: storeRootURL,
            store: manager.store,
            destinationBucketID: manager.bucketID(forItemID: item.id) ?? manager.activeBucketID
        )
        BucketActionRunner.run(type, items: [item], context: ctx, manager: manager)
    }

    /// Small wrapper type so `ForEach` can iterate `any QuickAction.Type`
    /// (metatypes themselves aren't `Identifiable`).
    private struct AnyActionType: Identifiable {
        let type: any QuickAction.Type
        var id: String { type.id }
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
            // Route through BucketImageCache so repeated renders (tab
            // switches, search re-filter, Observable state changes) don't
            // hit the disk on every pass.
            if let rel = item.fileRef?.cachedPath,
               let nsImage = BucketImageCache.shared.image(
                    for: storeRootURL.appendingPathComponent(rel)
               ) {
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
            // Epic 07 — if this text was OCR'd from an image, show the
            // source's thumbnail instead of a generic text glyph. Falls back
            // to the glyph when the source is gone or isn't an image.
            if let sourceImage = derivedFromImageThumbnail() {
                Image(nsImage: sourceImage).resizable().scaledToFill()
            } else {
                Image(systemName: "text.alignleft")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
            }
        case .color:
            let hex = item.colorHex ?? "#999999"
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(hex: hex) ?? .gray)
                .frame(width: 28, height: 28)
        }
    }

    /// Loads the NSImage of this item's source (if this item is derived from
    /// an image that still exists in some bucket). Returns nil in all other
    /// cases so the caller can fall back to the text glyph. Always hits the
    /// cache — derived text cards exist specifically *because* their source
    /// was already loaded, so the cache is almost always warm.
    private func derivedFromImageThumbnail() -> NSImage? {
        guard let sourceID = item.derivedFromItemID,
              let source = manager.findItem(id: sourceID),
              source.kind == .image,
              let rel = source.fileRef?.cachedPath
        else { return nil }
        return BucketImageCache.shared.image(
            for: storeRootURL.appendingPathComponent(rel)
        )
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
        // Epic 07 — derived items show provenance ("from <source>") instead
        // of the generic per-kind description. Takes precedence because it's
        // more informative at a glance.
        if let provenance = derivedProvenanceLine {
            return provenance
        }
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

    // MARK: - Epic 07 — derived-item provenance

    /// Secondary-line text for derived items: "from <source name>" for OCR,
    /// "translated from <lang>" for translations, etc. Nil for non-derived
    /// items so the default per-kind line applies.
    private var derivedProvenanceLine: String? {
        guard let action = item.derivedAction else { return nil }
        switch action {
        case ExtractTextAction.id:
            if let sourceID = item.derivedFromItemID,
               let source = manager.findItem(id: sourceID),
               let name = source.fileRef?.displayName, !name.isEmpty {
                return "from \(name)"
            }
            return "extracted from photo"
        case let a where a.hasPrefix("translate:"):
            // "translate:en-US" → "translated to en-US"
            let target = String(a.dropFirst("translate:".count))
            let pretty = Locale.current.localizedString(forIdentifier: target) ?? target
            return "translated to \(pretty)"
        case let a where a.hasPrefix("resize:"):
            return "resized \(a.dropFirst("resize:".count))%"
        case let a where a.hasPrefix("convert:"):
            return "converted to \(a.dropFirst("convert:".count).uppercased())"
        case "stripExif":
            return "metadata stripped"
        default:
            return nil
        }
    }

    /// SF Symbol name for the corner badge. Matches the `derivedAction`
    /// taxonomy — kept small so screen-reader users get consistent tooltips.
    private var derivedBadgeSymbol: String? {
        guard let action = item.derivedAction else { return nil }
        switch action {
        case ExtractTextAction.id:           return "text.viewfinder"
        case let a where a.hasPrefix("translate:"):
                                             return "character.bubble"
        case let a where a.hasPrefix("resize:"):
                                             return "arrow.down.right.and.arrow.up.left"
        case let a where a.hasPrefix("convert:"):
                                             return "arrow.triangle.2.circlepath"
        case "stripExif":                    return "eraser"
        default:                             return nil
        }
    }

    private var derivedBadgeColor: Color {
        guard let action = item.derivedAction else { return .gray }
        if action == ExtractTextAction.id { return .orange }
        if action.hasPrefix("translate:") { return .purple }
        if action.hasPrefix("resize:") || action.hasPrefix("convert:") || action == "stripExif" {
            return .blue
        }
        return .gray
    }

    /// Tooltip for the provenance badge — shown on hover over the badge itself.
    private var derivedBadgeHelp: String? {
        derivedProvenanceLine
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

