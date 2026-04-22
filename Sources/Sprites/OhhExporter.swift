import Foundation

/// `.snoroh` export / import.
///
/// Two on-disk formats, chosen per-ohh at export time:
///
/// - **v2 (preferred for Smart-Imported ohhs)** — embeds only the source sprite
///   sheet + per-status frame-input strings. On import, the pipeline re-runs
///   detection + cropping to regenerate each status sprite. Typical size win
///   is ~8× vs. v1 on anime-style sheets with many frames, which keeps exports
///   under marketplace upload caps.
///
/// - **v1 (legacy + manually-authored ohhs)** — embeds each status sprite as a
///   base64-encoded PNG. Still used when the ohh has no `smartImportMeta` or
///   its source-sheet file is missing on disk. Imported v1 files keep decoding
///   with the original per-status path.
///
/// Ported from ani-mime PR #100 (vietnguyenhoangw/ani-mime). Same versioning
/// scheme and JSON shape so `.animime` ↔ `.snoroh` are interchangeable at the
/// format level.
enum OhhExporter {

    // MARK: - File shape

    struct SnorohFile: Codable {
        let version: Int
        let name: String
        /// v1 only. Per-status base64 PNG + frame counts.
        let sprites: [String: SpriteData]?
        /// v2 only. Source sheet + per-status frame-input strings.
        let smartImportMeta: SmartImportMetaPayload?

        struct SpriteData: Codable {
            let frames: Int
            let data: String  // Base64-encoded PNG
        }

        struct SmartImportMetaPayload: Codable {
            let sourceSheet: String              // Base64-encoded PNG
            let frameInputs: [String: String]    // Status.rawValue → "1-5,3-1,..."
        }
    }

    enum ExportError: Error, LocalizedError {
        case ohhNotFound
        case spriteReadFailed(status: String)
        case sheetReadFailed
        case writeFailed(Error)

        var errorDescription: String? {
            switch self {
            case .ohhNotFound: return "Ohh not found"
            case .spriteReadFailed(let s): return "Failed to read sprite for \(s)"
            case .sheetReadFailed: return "Failed to read source sheet"
            case .writeFailed(let e): return "Failed to write file: \(e.localizedDescription)"
            }
        }
    }

    enum ImportError: Error, LocalizedError {
        case readFailed
        case invalidFormat
        case unsupportedVersion(Int)
        case missingSprite(status: String)
        case decodeFailed(status: String)
        case sheetDecodeFailed
        case frameDetectionFailed
        case invalidFrameInput(status: String)

        var errorDescription: String? {
            switch self {
            case .readFailed: return "Failed to read .snoroh file"
            case .invalidFormat: return "Invalid .snoroh file"
            case .unsupportedVersion(let v): return "Unsupported .snoroh version: \(v)"
            case .missingSprite(let s): return "Missing sprite data for \"\(s)\""
            case .decodeFailed(let s): return "Failed to decode sprite for \"\(s)\""
            case .sheetDecodeFailed: return "Failed to decode source sheet"
            case .frameDetectionFailed: return "Could not detect sprite rows in source sheet"
            case .invalidFrameInput(let s): return "No frames assigned for \"\(s)\""
            }
        }
    }

    // MARK: - Export

    static func export(ohhID: String, to destination: URL) throws {
        let jsonData = try exportData(ohhID: ohhID)
        do {
            try jsonData.write(to: destination, options: .atomic)
        } catch {
            throw ExportError.writeFailed(error)
        }
    }

    /// Build the `.snoroh` JSON payload in memory. Used by both file export and
    /// Share to Marketplace. Chooses v2 when the ohh has a Smart-Import source
    /// sheet on disk, v1 otherwise.
    static func exportData(ohhID: String) throws -> Data {
        let manager = CustomOhhManager.shared
        guard let ohh = manager.ohh(withID: ohhID) else {
            throw ExportError.ohhNotFound
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        // v2 path: embed source sheet + frame inputs. Only available for
        // Smart-Imported ohhs whose sheet is still on disk — otherwise we
        // gracefully fall back to v1.
        if let meta = ohh.smartImportMeta {
            let sheetURL = manager.spritePath(fileName: meta.sheetFileName)
            if let sheetData = try? Data(contentsOf: sheetURL) {
                let file = SnorohFile(
                    version: 2,
                    name: ohh.name,
                    sprites: nil,
                    smartImportMeta: .init(
                        sourceSheet: sheetData.base64EncodedString(),
                        frameInputs: meta.frameInputs
                    )
                )
                return try encoder.encode(file)
            }
            // Sheet gone missing — fall through to v1 as a safety net so the
            // user still gets an exportable file (just larger).
        }

        // v1 fallback: per-status base64 sprites. Only the sprite-bearing
        // statuses are serialized — display-only statuses like `.carrying`
        // are intentionally skipped so `.snoroh` payloads stay forward- and
        // backward-compatible with older snor-oh builds.
        var spriteEntries: [String: SnorohFile.SpriteData] = [:]
        for status in Status.spriteStatuses {
            guard let entry = ohh.sprite(for: status) else {
                throw ExportError.spriteReadFailed(status: status.rawValue)
            }
            let path = manager.spritePath(fileName: entry.fileName)
            guard let data = try? Data(contentsOf: path) else {
                throw ExportError.spriteReadFailed(status: status.rawValue)
            }
            spriteEntries[status.rawValue] = .init(
                frames: entry.frames,
                data: data.base64EncodedString()
            )
        }

        let file = SnorohFile(
            version: 1,
            name: ohh.name,
            sprites: spriteEntries,
            smartImportMeta: nil
        )
        return try encoder.encode(file)
    }

    static func ohhName(ohhID: String) -> String? {
        CustomOhhManager.shared.ohh(withID: ohhID)?.name
    }

    private static let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f
    }()

    static func defaultFilename(for ohh: CustomOhhData) -> String {
        let safeName = ohh.name.replacingOccurrences(
            of: "[^a-zA-Z0-9_-]",
            with: "-",
            options: .regularExpression
        )
        let date = dateFormatter.string(from: Date())
        return "snoroh-\(safeName)-\(date).snoroh"
    }

    // MARK: - Import

    @discardableResult
    static func importOhh(from source: URL) throws -> String {
        guard let fileData = try? Data(contentsOf: source) else {
            throw ImportError.readFailed
        }

        let file: SnorohFile
        do {
            file = try JSONDecoder().decode(SnorohFile.self, from: fileData)
        } catch {
            throw ImportError.invalidFormat
        }

        guard !file.name.isEmpty else {
            throw ImportError.invalidFormat
        }

        switch file.version {
        case 1:
            return try importV1(file: file)
        case 2:
            return try importV2(file: file)
        default:
            throw ImportError.unsupportedVersion(file.version)
        }
    }

    // MARK: - Version-specific import paths

    private static func importV1(file: SnorohFile) throws -> String {
        guard let sprites = file.sprites else {
            throw ImportError.invalidFormat
        }

        var blobs: [Status: (data: Data, frames: Int)] = [:]
        for status in Status.spriteStatuses {
            guard let entry = sprites[status.rawValue], !entry.data.isEmpty else {
                throw ImportError.missingSprite(status: status.rawValue)
            }
            guard let decoded = Data(base64Encoded: entry.data) else {
                throw ImportError.decodeFailed(status: status.rawValue)
            }
            guard SmartImport.loadImage(from: decoded) != nil else {
                throw ImportError.decodeFailed(status: status.rawValue)
            }
            blobs[status] = (data: decoded, frames: entry.frames)
        }

        guard let id = CustomOhhManager.shared.addOhhFromBlobs(
            name: file.name,
            spriteBlobs: blobs
        ) else {
            throw ImportError.invalidFormat
        }
        return id
    }

    /// v2 import re-runs the Smart-Import pipeline (detect rows → extract
    /// frames → crop per-status strips by frameInputs) instead of trusting
    /// embedded per-status blobs. Matches ani-mime PR #100's round-trip.
    private static func importV2(file: SnorohFile) throws -> String {
        guard let meta = file.smartImportMeta,
              !meta.sourceSheet.isEmpty else {
            throw ImportError.invalidFormat
        }
        guard let sheetData = Data(base64Encoded: meta.sourceSheet),
              let image = SmartImport.loadImage(from: sheetData) else {
            throw ImportError.sheetDecodeFailed
        }

        // Full detection + bg removal in one pass.
        guard let processed = SmartImport.processSheet(image: image) else {
            throw ImportError.frameDetectionFailed
        }
        let allFrames = processed.frames
        guard !allFrames.isEmpty else {
            throw ImportError.frameDetectionFailed
        }

        // Regenerate one strip per status from its frame-input string. Any
        // status with no resolvable indices fails fast — matches ani-mime's
        // strictness (the user would otherwise get an empty animation).
        var blobs: [Status: (data: Data, frames: Int)] = [:]
        var frameInputsByStatus: [Status: String] = [:]
        for status in Status.spriteStatuses {
            let input = meta.frameInputs[status.rawValue] ?? ""
            let indices = SmartImport.parseFrameInput(input, maxFrames: allFrames.count)
            guard !indices.isEmpty else {
                throw ImportError.invalidFrameInput(status: status.rawValue)
            }
            guard let strip = SmartImport.createStripFromFrames(
                context: processed.context,
                frames: allFrames,
                indices: indices
            ) else {
                throw ImportError.invalidFrameInput(status: status.rawValue)
            }
            blobs[status] = (data: strip.pngData, frames: strip.frames)
            frameInputsByStatus[status] = input
        }

        guard let id = CustomOhhManager.shared.addOhhFromBlobs(
            name: file.name,
            spriteBlobs: blobs,
            smartImportMeta: (sheetData: sheetData, frameInputs: frameInputsByStatus)
        ) else {
            throw ImportError.invalidFormat
        }
        return id
    }
}
