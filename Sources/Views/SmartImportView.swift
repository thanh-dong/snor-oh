import SwiftUI
import UniformTypeIdentifiers

// MARK: - Smart Import Sheet

struct SmartImportSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var ohhName = ""
    @State private var sourceImage: CGImage?
    @State private var processedCtx: CGContext?
    @State private var detectedFrames: [SmartImport.Frame] = []
    @State private var framePreviews: [CGImage] = []
    @State private var frameInputs: [Status: String] = [:]
    @State private var processing = false
    @State private var saving = false
    @State private var errorMessage: String?
    @State private var previewingStatus: Status?
    @State private var draggedIndex: Int?
    @State private var hoveredIndex: Int?
    @State private var framesEdited = false
    @State private var statusDragStatus: String?
    @State private var statusDragPos: Int?
    @State private var statusHoverStatus: String?
    @State private var statusHoverPos: Int?

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                Text("Smart Import").font(.headline)
                Spacer()
                if !detectedFrames.isEmpty {
                    Text("\(detectedFrames.count) frames")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.blue.opacity(0.15))
                        .cornerRadius(4)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            Divider()

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Top section: name + source
                    topSection

                    if let err = errorMessage {
                        Text(err).font(.caption).foregroundStyle(.red)
                    }

                    // Frame grid
                    if !framePreviews.isEmpty {
                        frameGridSection
                    }

                    // Per-status assignment with previews
                    if !detectedFrames.isEmpty {
                        statusAssignmentSection
                    }
                }
                .padding(20)
            }

            Divider()

            // Footer
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 560, height: 640)
    }

    // MARK: - Top Section

    private var topSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text("Name")
                    .frame(width: 60, alignment: .trailing)
                    .foregroundStyle(.secondary)
                TextField("Pet name", text: $ohhName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
            }
            HStack(spacing: 12) {
                Text("Source")
                    .frame(width: 60, alignment: .trailing)
                    .foregroundStyle(.secondary)
                Button {
                    pickSpriteSheet()
                } label: {
                    if processing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label(
                            sourceImage != nil ? "Change Sprite Sheet" : "Pick Sprite Sheet",
                            systemImage: "photo.on.rectangle"
                        )
                    }
                }
                .disabled(processing)
            }
        }
    }

    // MARK: - Frame Grid

    private var frameGridSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Detected Frames")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text("Drag to reorder · hover to delete")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            LazyVGrid(columns: Array(repeating: GridItem(.fixed(52), spacing: 4), count: 8), spacing: 4) {
                ForEach(0..<framePreviews.count, id: \.self) { i in
                    frameTile(i)
                }
            }
        }
    }

    private func frameTile(_ i: Int) -> some View {
        VStack(spacing: 1) {
            ZStack(alignment: .topTrailing) {
                Image(decorative: framePreviews[i], scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 44, height: 44)
                    .background(Color.secondary.opacity(0.06))
                    .cornerRadius(3)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(draggedIndex == i ? Color.accentColor : Color.clear, lineWidth: 1.5)
                    )
                    .opacity(draggedIndex == i ? 0.4 : 1)

                if hoveredIndex == i {
                    Button {
                        deleteFrame(at: i)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .red)
                            .shadow(radius: 1)
                    }
                    .buttonStyle(.borderless)
                    .help("Delete frame")
                    .offset(x: 5, y: -5)
                }
            }
            Text("\(i + 1)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering { hoveredIndex = i }
            else if hoveredIndex == i { hoveredIndex = nil }
        }
        .onDrag {
            draggedIndex = i
            return NSItemProvider(object: "\(i)" as NSString)
        }
        .onDrop(of: [.text], delegate: FrameDropDelegate(
            targetIndex: i,
            draggedIndex: $draggedIndex,
            onMove: { src, dst in moveFrame(from: src, to: dst) }
        ))
    }

    // MARK: - Status Assignment

    private var statusAssignmentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Assign Frames to Status")
                .font(.subheadline.weight(.medium))

            ForEach(Status.spriteStatuses, id: \.self) { status in
                statusRow(status)
            }

            Text("Ranges: \"1-5\", \"1,3,5\", or \"1-3,5,7-9\" (1-based)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func statusRow(_ status: Status) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                // Status label
                Text(status.rawValue)
                    .font(.system(.caption, design: .monospaced).weight(.medium))
                    .frame(width: 85, alignment: .trailing)
                    .foregroundStyle(.secondary)

                // Frame range input
                TextField("e.g. 1-5", text: binding(for: status))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 120)

                // Frame count
                let count = parsedIndices(for: status).count
                Text("\(count)f")
                    .font(.caption2.monospaced())
                    .foregroundStyle(count > 0 ? Color.secondary : Color.red)
                    .frame(width: 24)

                // Preview button
                Button {
                    previewingStatus = (previewingStatus == status) ? nil : status
                } label: {
                    Image(systemName: "play.circle")
                        .font(.callout)
                        .foregroundStyle(count > 0 ? Color.blue : Color.gray)
                }
                .buttonStyle(.borderless)
                .disabled(count == 0)
                .popover(isPresented: Binding(
                    get: { previewingStatus == status },
                    set: { if !$0 { previewingStatus = nil } }
                )) {
                    statusPreviewPopover(status)
                }
            }

            // Thumbnail strip for assigned frames (drag-reorder + hover-delete)
            let indices = parsedIndices(for: status)
            if !indices.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(Array(indices.enumerated()), id: \.offset) { pos, idx in
                            if idx < framePreviews.count {
                                statusFrameTile(status, frameIndex: idx, at: pos)
                            }
                        }
                    }
                    .padding(.leading, 93)
                    .padding(.vertical, 3)
                }
            }
        }
    }

    private func statusFrameTile(_ status: Status, frameIndex idx: Int, at pos: Int) -> some View {
        let key = status.rawValue
        let isHovered = statusHoverStatus == key && statusHoverPos == pos
        let isDragged = statusDragStatus == key && statusDragPos == pos

        return ZStack(alignment: .topTrailing) {
            Image(decorative: framePreviews[idx], scale: 1)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(width: 28, height: 28)
                .background(Color.secondary.opacity(0.04))
                .cornerRadius(2)
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(isDragged ? Color.accentColor : Color.clear, lineWidth: 1)
                )
                .opacity(isDragged ? 0.4 : 1)

            if isHovered {
                Button {
                    deleteFromStatus(status, at: pos)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .red)
                        .shadow(radius: 1)
                }
                .buttonStyle(.borderless)
                .help("Remove from \(status.rawValue)")
                .offset(x: 4, y: -4)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering {
                statusHoverStatus = key
                statusHoverPos = pos
            } else if statusHoverStatus == key && statusHoverPos == pos {
                statusHoverStatus = nil
                statusHoverPos = nil
            }
        }
        .onDrag {
            statusDragStatus = key
            statusDragPos = pos
            return NSItemProvider(object: "\(pos)" as NSString)
        }
        .onDrop(of: [.text], delegate: StatusFrameDropDelegate(
            statusKey: key,
            targetPos: pos,
            dragStatus: $statusDragStatus,
            dragPos: $statusDragPos,
            onMove: { src, dst in moveInStatus(status, from: src, to: dst) }
        ))
    }

    // MARK: - Animation Preview Popover

    private func statusPreviewPopover(_ status: Status) -> some View {
        let indices = parsedIndices(for: status)
        let previewFrames = indices.compactMap { idx -> CGImage? in
            idx < framePreviews.count ? framePreviews[idx] : nil
        }
        return StatusAnimationPreview(
            statusName: status.rawValue,
            frames: previewFrames
        )
    }

    // MARK: - Helpers

    private var canSave: Bool {
        !ohhName.isEmpty && !detectedFrames.isEmpty && !saving
            && Status.spriteStatuses.allSatisfy { !parsedIndices(for: $0).isEmpty }
    }

    private func binding(for status: Status) -> Binding<String> {
        Binding(
            get: { frameInputs[status] ?? "" },
            set: { frameInputs[status] = $0 }
        )
    }

    private func parsedIndices(for status: Status) -> [Int] {
        let text = frameInputs[status] ?? ""
        guard !text.isEmpty else { return [] }
        return SmartImport.parseFrameInput(text, maxFrames: detectedFrames.count)
    }

    // MARK: - Frame Mutation

    private func deleteFrame(at pos: Int) {
        guard pos >= 0, pos < detectedFrames.count else { return }
        let n = detectedFrames.count
        var oldToNew = [Int?](repeating: nil, count: n)
        for i in 0..<n {
            if i == pos { oldToNew[i] = nil }
            else if i < pos { oldToNew[i] = i }
            else { oldToNew[i] = i - 1 }
        }
        detectedFrames.remove(at: pos)
        framePreviews.remove(at: pos)
        if hoveredIndex == pos { hoveredIndex = nil }
        framesEdited = true
        applyRemap(oldToNew)
    }

    private func moveFrame(from src: Int, to dst: Int) {
        guard src != dst else { return }
        guard src >= 0, src < detectedFrames.count else { return }
        guard dst >= 0, dst < detectedFrames.count else { return }

        let n = detectedFrames.count
        var order = Array(0..<n)
        let moved = order.remove(at: src)
        let insertAt = min(dst, order.count)
        order.insert(moved, at: insertAt)

        var oldToNew = [Int?](repeating: nil, count: n)
        for (newPos, oldPos) in order.enumerated() {
            oldToNew[oldPos] = newPos
        }

        let frame = detectedFrames.remove(at: src)
        let preview = framePreviews.remove(at: src)
        detectedFrames.insert(frame, at: insertAt)
        framePreviews.insert(preview, at: insertAt)

        framesEdited = true
        applyRemap(oldToNew)
    }

    // MARK: - Per-Status Mutation

    private func deleteFromStatus(_ status: Status, at pos: Int) {
        var indices = parsedIndices(for: status)
        guard pos >= 0, pos < indices.count else { return }
        indices.remove(at: pos)
        frameInputs[status] = reserializeIndices(indices)
        if statusHoverStatus == status.rawValue && statusHoverPos == pos {
            statusHoverStatus = nil
            statusHoverPos = nil
        }
    }

    private func moveInStatus(_ status: Status, from src: Int, to dst: Int) {
        guard src != dst else { return }
        var indices = parsedIndices(for: status)
        guard src >= 0, src < indices.count, dst >= 0, dst < indices.count else { return }
        let moved = indices.remove(at: src)
        let insertAt = min(dst, indices.count)
        indices.insert(moved, at: insertAt)
        frameInputs[status] = reserializeIndices(indices)
    }

    /// Rewrite each status's text input after a delete/reorder so the same
    /// original frames remain assigned, with dropped frames removed.
    private func applyRemap(_ oldToNew: [Int?]) {
        var newInputs: [Status: String] = [:]
        for status in Status.spriteStatuses {
            let oldIdx = parsedIndicesRaw(for: status, maxFrames: oldToNew.count)
            let newIdx = oldIdx.compactMap { i -> Int? in
                guard i < oldToNew.count else { return nil }
                return oldToNew[i]
            }
            newInputs[status] = reserializeIndices(newIdx)
        }
        frameInputs = newInputs
    }

    /// Like parsedIndices but clamps against an explicit maxFrames (pre-mutation count).
    private func parsedIndicesRaw(for status: Status, maxFrames: Int) -> [Int] {
        let text = frameInputs[status] ?? ""
        guard !text.isEmpty, maxFrames > 0 else { return [] }
        return SmartImport.parseFrameInput(text, maxFrames: maxFrames)
    }

    /// Serialize 0-based indices into a 1-based range string like "1-3,5".
    /// Preserves the input order: "3,4,5,1,2" → "3-5,1-2" (runs only compacted
    /// when consecutive indices appear in ascending order).
    private func reserializeIndices(_ indices: [Int]) -> String {
        guard !indices.isEmpty else { return "" }
        var parts: [String] = []
        var start = indices[0]
        var prev = indices[0]
        for k in 1..<indices.count {
            let curr = indices[k]
            if curr == prev + 1 {
                prev = curr
            } else {
                parts.append(start == prev ? "\(start + 1)" : "\(start + 1)-\(prev + 1)")
                start = curr
                prev = curr
            }
        }
        parts.append(start == prev ? "\(start + 1)" : "\(start + 1)-\(prev + 1)")
        return parts.joined(separator: ",")
    }

    // MARK: - Pick Sprite Sheet

    private func pickSpriteSheet() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .gif]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a sprite sheet image"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        processing = true
        errorMessage = nil

        DispatchQueue.global(qos: .userInitiated).async {
            guard let image = SmartImport.loadImage(from: url) else {
                DispatchQueue.main.async { errorMessage = "Failed to load image"; processing = false }
                return
            }

            guard let result = SmartImport.processSheet(image: image) else {
                DispatchQueue.main.async { errorMessage = "Failed to process sprite sheet"; processing = false }
                return
            }

            guard let snapshot = result.context.makeImage() else {
                DispatchQueue.main.async { errorMessage = "Failed to generate preview"; processing = false }
                return
            }

            // Generate frame thumbnails
            let previews = result.frames.compactMap { frame -> CGImage? in
                let rect = CGRect(
                    x: frame.x1, y: frame.y1,
                    width: frame.x2 - frame.x1, height: frame.y2 - frame.y1
                )
                guard let cropped = snapshot.cropping(to: rect) else { return nil }
                return scaleThumbnail(cropped, size: 48)
            }

            // Auto-distribute frames evenly across sprite-bearing statuses.
            // `.carrying` opts out — it reuses the idle sheet at render time.
            let allStatuses = Status.spriteStatuses
            let total = result.frames.count
            var inputs: [Status: String] = [:]
            let perStatus = max(1, total / allStatuses.count)
            var offset = 1
            for (i, status) in allStatuses.enumerated() {
                let count = (i == allStatuses.count - 1)
                    ? max(1, total - offset + 1)
                    : min(perStatus, total - offset + 1)
                guard offset <= total else {
                    inputs[status] = "\(total)"
                    continue
                }
                let end = min(offset + count - 1, total)
                inputs[status] = end > offset ? "\(offset)-\(end)" : "\(offset)"
                offset = end + 1
            }

            let defaultName = String(url.deletingPathExtension().lastPathComponent.prefix(20))
                .replacingOccurrences(of: "[^a-zA-Z0-9 _-]", with: "", options: .regularExpression)

            DispatchQueue.main.async {
                sourceImage = image
                processedCtx = result.context
                detectedFrames = result.frames
                framePreviews = previews
                frameInputs = inputs
                framesEdited = false
                draggedIndex = nil
                hoveredIndex = nil
                if ohhName.isEmpty { ohhName = defaultName }
                processing = false
            }
        }
    }

    private func scaleThumbnail(_ image: CGImage, size: Int) -> CGImage? {
        guard let ctx = SmartImport.createRGBAContext(width: size, height: size) else { return nil }
        // No flip needed: CG draws image right-side-up in default coords,
        // and makeImage() produces row 0 = visual top for SwiftUI display.
        let scale = min(CGFloat(size) / CGFloat(image.width),
                       CGFloat(size) / CGFloat(image.height))
        let sw = Int((CGFloat(image.width) * scale).rounded())
        let sh = Int((CGFloat(image.height) * scale).rounded())
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: (size - sw) / 2, y: (size - sh) / 2, width: sw, height: sh))
        return ctx.makeImage()
    }

    // MARK: - Save

    private func save() {
        guard let ctx = processedCtx, !detectedFrames.isEmpty else { return }
        saving = true

        DispatchQueue.global(qos: .userInitiated).async {
            var blobs: [Status: (data: Data, frames: Int)] = [:]

            for status in Status.spriteStatuses {
                let indices = parsedIndices(for: status)
                guard !indices.isEmpty else {
                    DispatchQueue.main.async {
                        errorMessage = "No frames assigned for \(status.rawValue)"
                        saving = false
                    }
                    return
                }

                guard let strip = SmartImport.createStripFromFrames(
                    context: ctx, frames: detectedFrames, indices: indices
                ) else {
                    DispatchQueue.main.async {
                        errorMessage = "Failed to create strip for \(status.rawValue)"
                        saving = false
                    }
                    return
                }

                blobs[status] = (data: strip.pngData, frames: strip.frames)
            }

            var smartMeta: (sheetData: Data, frameInputs: [Status: String])?
            if !framesEdited, let sourceImage, let pngData = SmartImport.pngData(from: sourceImage) {
                smartMeta = (sheetData: pngData, frameInputs: frameInputs)
            }

            let name = String(ohhName.prefix(20))

            DispatchQueue.main.async {
                let id = CustomOhhManager.shared.addOhhFromBlobs(
                    name: name, spriteBlobs: blobs, smartImportMeta: smartMeta
                )
                saving = false
                if id != nil { dismiss() }
                else { errorMessage = "Failed to save" }
            }
        }
    }
}

// MARK: - Drop Delegate

private struct FrameDropDelegate: DropDelegate {
    let targetIndex: Int
    @Binding var draggedIndex: Int?
    let onMove: (Int, Int) -> Void

    func performDrop(info: DropInfo) -> Bool {
        guard let src = draggedIndex else { return false }
        draggedIndex = nil
        if src != targetIndex {
            onMove(src, targetIndex)
        }
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}

private struct StatusFrameDropDelegate: DropDelegate {
    let statusKey: String
    let targetPos: Int
    @Binding var dragStatus: String?
    @Binding var dragPos: Int?
    let onMove: (Int, Int) -> Void

    func performDrop(info: DropInfo) -> Bool {
        let src = dragPos
        let from = dragStatus
        dragStatus = nil
        dragPos = nil
        guard from == statusKey, let s = src, s != targetPos else { return false }
        onMove(s, targetPos)
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        if dragStatus == statusKey {
            return DropProposal(operation: .move)
        }
        return DropProposal(operation: .forbidden)
    }
}

// MARK: - Animation Preview

private struct StatusAnimationPreview: View {
    let statusName: String
    let frames: [CGImage]

    @State private var currentIndex = 0
    @State private var timer: Timer?

    var body: some View {
        VStack(spacing: 8) {
            if !frames.isEmpty, currentIndex < frames.count {
                Image(decorative: frames[currentIndex], scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 96, height: 96)
            } else {
                Color.clear.frame(width: 96, height: 96)
            }

            Text("\(statusName) — \(currentIndex + 1)/\(frames.count)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .onAppear { startAnimation() }
        .onDisappear { timer?.invalidate(); timer = nil }
    }

    private func startAnimation() {
        guard frames.count > 1 else { return }
        let t = Timer(timeInterval: 0.1, repeats: true) { _ in
            currentIndex = (currentIndex + 1) % frames.count
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
}
