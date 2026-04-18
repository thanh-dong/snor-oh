import SwiftUI
import UniformTypeIdentifiers

/// Sheet for importing a sprite sheet and auto-detecting frames.
/// User picks a PNG → frames are detected → user assigns ranges to statuses → save.
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

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Smart Import").font(.headline)
                Spacer()
                if !detectedFrames.isEmpty {
                    Text("\(detectedFrames.count) frames detected")
                        .font(.caption)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.blue.opacity(0.15))
                        .cornerRadius(4)
                }
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Name field
                    HStack {
                        Text("Name")
                            .frame(width: 50, alignment: .trailing)
                        TextField("Pet name", text: $ohhName)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 200)
                    }

                    // Source picker
                    HStack {
                        Text("Source")
                            .frame(width: 50, alignment: .trailing)
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

                    // Error
                    if let err = errorMessage {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(.leading, 56)
                    }

                    // Frame preview grid
                    if !framePreviews.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Detected Frames")
                                .font(.subheadline.weight(.medium))
                                .padding(.leading, 56)

                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 4) {
                                    ForEach(0..<framePreviews.count, id: \.self) { i in
                                        VStack(spacing: 2) {
                                            Image(decorative: framePreviews[i], scale: 1)
                                                .interpolation(.none)
                                                .resizable()
                                                .scaledToFit()
                                                .frame(width: 48, height: 48)
                                                .background(Color.secondary.opacity(0.05))
                                                .cornerRadius(4)
                                            Text("\(i + 1)")
                                                .font(.system(.caption2, design: .monospaced))
                                                .foregroundStyle(.tertiary)
                                        }
                                    }
                                }
                                .padding(.horizontal, 56)
                            }
                        }
                    }

                    // Frame assignment
                    if !detectedFrames.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Frame Assignment")
                                .font(.subheadline.weight(.medium))
                                .padding(.leading, 56)

                            ForEach(Status.allCases, id: \.self) { status in
                                HStack {
                                    Text(status.rawValue)
                                        .font(.caption.monospaced())
                                        .frame(width: 90, alignment: .trailing)
                                        .foregroundStyle(.secondary)
                                    TextField("e.g. 1-5", text: binding(for: status))
                                        .textFieldStyle(.roundedBorder)
                                        .font(.system(.body, design: .monospaced))
                                        .frame(maxWidth: 150)
                                    let count = parseCount(for: status)
                                    if count > 0 {
                                        Text("\(count)f")
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }

                            Text("Use 1-based ranges: \"1-5\", \"1,3,5\", or \"1-3,5,7-9\"")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 96)
                        }
                    }
                }
                .padding()
            }

            Divider()

            // Actions
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if saving {
                    ProgressView().controlSize(.small)
                }
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding()
        }
        .frame(width: 480, height: 520)
    }

    // MARK: - Computed

    private var canSave: Bool {
        !ohhName.isEmpty && !detectedFrames.isEmpty && !saving
            && Status.allCases.allSatisfy { !inputText(for: $0).isEmpty }
    }

    private func inputText(for status: Status) -> String {
        frameInputs[status] ?? ""
    }

    private func binding(for status: Status) -> Binding<String> {
        Binding(
            get: { frameInputs[status] ?? "" },
            set: { frameInputs[status] = $0 }
        )
    }

    private func parseCount(for status: Status) -> Int {
        let text = frameInputs[status] ?? ""
        guard !text.isEmpty else { return 0 }
        return SmartImport.parseFrameInput(text, maxFrames: detectedFrames.count).count
    }

    // MARK: - Pick

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
                DispatchQueue.main.async {
                    errorMessage = "Failed to load image"
                    processing = false
                }
                return
            }

            guard let result = SmartImport.processSheet(image: image) else {
                DispatchQueue.main.async {
                    errorMessage = "Failed to process sprite sheet"
                    processing = false
                }
                return
            }

            // Generate frame previews
            guard let snapshot = result.context.makeImage() else {
                DispatchQueue.main.async {
                    errorMessage = "Failed to generate preview"
                    processing = false
                }
                return
            }

            let previews = result.frames.compactMap { frame -> CGImage? in
                let rect = CGRect(
                    x: frame.x1, y: frame.y1,
                    width: frame.x2 - frame.x1, height: frame.y2 - frame.y1
                )
                guard let cropped = snapshot.cropping(to: rect) else { return nil }

                // Scale to 48x48 preview
                let size = 48
                guard let ctx = SmartImport.createRGBAContext(width: size, height: size) else { return nil }
                ctx.translateBy(x: 0, y: CGFloat(size))
                ctx.scaleBy(x: 1, y: -1)
                let scale = min(CGFloat(size) / CGFloat(cropped.width),
                               CGFloat(size) / CGFloat(cropped.height))
                let sw = Int((CGFloat(cropped.width) * scale).rounded())
                let sh = Int((CGFloat(cropped.height) * scale).rounded())
                ctx.interpolationQuality = .none
                ctx.draw(cropped, in: CGRect(
                    x: (size - sw) / 2, y: (size - sh) / 2,
                    width: sw, height: sh
                ))
                return ctx.makeImage()
            }

            // Auto-distribute frames across statuses
            let allStatuses = Status.allCases
            let total = result.frames.count
            var inputs: [Status: String] = [:]
            let perStatus = max(1, total / allStatuses.count)
            var offset = 1
            for (i, status) in allStatuses.enumerated() {
                let count = (i == allStatuses.count - 1)
                    ? max(1, total - offset + 1)
                    : min(perStatus, total - offset + 1)
                let end = offset + count - 1
                inputs[status] = end > offset ? "\(offset)-\(end)" : "\(offset)"
                offset = end + 1
            }

            // Default name from filename
            let defaultName = url.deletingPathExtension().lastPathComponent
                .prefix(20)
                .replacingOccurrences(of: "[^a-zA-Z0-9 _-]", with: "", options: .regularExpression)

            DispatchQueue.main.async {
                sourceImage = image
                processedCtx = result.context
                detectedFrames = result.frames
                framePreviews = previews
                frameInputs = inputs
                if ohhName.isEmpty {
                    ohhName = String(defaultName)
                }
                processing = false
            }
        }
    }

    // MARK: - Save

    private func save() {
        guard let ctx = processedCtx, !detectedFrames.isEmpty else { return }
        saving = true

        DispatchQueue.global(qos: .userInitiated).async {
            var blobs: [Status: (data: Data, frames: Int)] = [:]

            for status in Status.allCases {
                let input = frameInputs[status] ?? ""
                let indices = SmartImport.parseFrameInput(input, maxFrames: detectedFrames.count)
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

            // Build smart import metadata for re-editing
            var metaInputs: [Status: String] = [:]
            for (status, text) in frameInputs {
                metaInputs[status] = text
            }

            // Save source sheet for re-editing
            var smartMeta: (sheetData: Data, frameInputs: [Status: String])?
            if let sourceImage, let pngData = SmartImport.pngData(from: sourceImage) {
                smartMeta = (sheetData: pngData, frameInputs: metaInputs)
            }

            let name = String(ohhName.prefix(20))

            DispatchQueue.main.async {
                let id = CustomOhhManager.shared.addOhhFromBlobs(
                    name: name,
                    spriteBlobs: blobs,
                    smartImportMeta: smartMeta
                )

                saving = false
                if id != nil {
                    dismiss()
                } else {
                    errorMessage = "Failed to save custom ohh"
                }
            }
        }
    }
}
