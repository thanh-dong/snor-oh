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
            Text("Detected Frames")
                .font(.subheadline.weight(.medium))

            LazyVGrid(columns: Array(repeating: GridItem(.fixed(52), spacing: 4), count: 8), spacing: 4) {
                ForEach(0..<framePreviews.count, id: \.self) { i in
                    VStack(spacing: 1) {
                        Image(decorative: framePreviews[i], scale: 1)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 44, height: 44)
                            .background(Color.secondary.opacity(0.06))
                            .cornerRadius(3)
                        Text("\(i + 1)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    // MARK: - Status Assignment

    private var statusAssignmentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Assign Frames to Status")
                .font(.subheadline.weight(.medium))

            ForEach(Status.allCases, id: \.self) { status in
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

            // Thumbnail strip for assigned frames
            let indices = parsedIndices(for: status)
            if !indices.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(indices, id: \.self) { idx in
                            if idx < framePreviews.count {
                                Image(decorative: framePreviews[idx], scale: 1)
                                    .interpolation(.none)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 28, height: 28)
                                    .background(Color.secondary.opacity(0.04))
                                    .cornerRadius(2)
                            }
                        }
                    }
                    .padding(.leading, 93)
                }
            }
        }
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
            && Status.allCases.allSatisfy { !parsedIndices(for: $0).isEmpty }
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

            // Auto-distribute frames evenly across statuses
            let allStatuses = Status.allCases
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

            for status in Status.allCases {
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
            if let sourceImage, let pngData = SmartImport.pngData(from: sourceImage) {
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
