import Foundation
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics

// MARK: - ResizeImageAction

/// Scales an image by a factor (typically 0.25 / 0.5 / custom). Uses ImageIO's
/// thumbnail pipeline because:
///   1. It's the fastest path on every Apple architecture (hardware-accelerated).
///   2. It respects EXIF orientation automatically (`kCGImageSourceCreateThumbnailWithTransform`).
///   3. It produces high-quality downsampled pixels with no tiling artifacts.
///
/// Output format mirrors input (PNG→PNG, JPEG→JPEG, HEIC→HEIC). Format
/// conversion is `ConvertImageAction`'s job.
enum ResizeImageAction: QuickAction {
    static let id = "resize-image"
    static let title = "Resize image"

    /// `params["scale"]` defaults to `"0.5"` when caller didn't specify.
    /// Clamped to `(0, 1]` — upscaling is intentionally unsupported because
    /// thumbnail-based resize is downsample-only.
    static func appliesTo(_ items: [BucketItem]) -> Bool {
        !items.isEmpty && items.allSatisfy { $0.kind == .image }
    }

    static func perform(_ items: [BucketItem], context: ActionContext) async throws -> [BucketItem] {
        guard !items.isEmpty else { throw QuickActionError.noInput }
        let scale = Double(context.params["scale"] ?? "0.5") ?? 0.5
        let clampedScale = max(0.01, min(1.0, scale))
        var out: [BucketItem] = []
        for item in items {
            try Task.checkCancellation()
            let derived = try await resize(item: item, scale: clampedScale, context: context)
            out.append(derived)
        }
        return out
    }

    private static func resize(
        item: BucketItem,
        scale: Double,
        context: ActionContext
    ) async throws -> BucketItem {
        guard let rel = item.fileRef?.cachedPath else {
            throw QuickActionError.missingFile(path: "<no cachedPath>")
        }
        let srcURL = context.storeRootURL.appendingPathComponent(rel)
        guard let data = try? Data(contentsOf: srcURL) else {
            throw QuickActionError.missingFile(path: srcURL.path)
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let imageProps = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = imageProps[kCGImagePropertyPixelWidth] as? Int,
              let height = imageProps[kCGImagePropertyPixelHeight] as? Int
        else {
            throw QuickActionError.imageLoadFailed
        }

        let maxDim = max(width, height)
        let targetMax = max(1, Int(Double(maxDim) * scale))
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: targetMax,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) else {
            throw QuickActionError.imageLoadFailed
        }

        // Preserve the source UTI so PNG stays PNG.
        let sourceUTI = (CGImageSourceGetType(source) as String?) ?? UTType.png.identifier
        guard let outData = encode(thumb, uti: sourceUTI) else {
            throw QuickActionError.imageEncodeFailed
        }

        let newID = UUID()
        let ext = UTType(sourceUTI)?.preferredFilenameExtension ?? "png"
        let relPath = try await context.store.writeSidecar(
            outData,
            bucketID: context.destinationBucketID,
            itemID: newID,
            subdir: "images",
            ext: ext
        )

        let displayName = makeDerivedName(
            original: item.fileRef?.displayName,
            suffix: "@\(Int(scale * 100))%"
        )

        let fileRef = BucketItem.FileRef(
            originalPath: "",
            cachedPath: relPath,
            byteSize: Int64(outData.count),
            uti: sourceUTI,
            displayName: displayName
        )

        return BucketItem(
            id: newID,
            kind: .image,
            sourceBundleID: item.sourceBundleID,
            fileRef: fileRef,
            derivedFromItemID: item.id,
            derivedAction: "resize:\(Int(scale * 100))"
        )
    }

    private static func encode(_ image: CGImage, uti: String) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, uti as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}

// MARK: - ConvertImageAction

/// Re-encodes an image in a different format. Target formats:
///   - PNG (`public.png`) — lossless
///   - JPEG (`public.jpeg`) — default quality 0.85 (override via `params["quality"]`)
///   - HEIC (`public.heic`) — Apple's modern format, best size/quality tradeoff
enum ConvertImageAction: QuickAction {
    static let id = "convert-image"
    static let title = "Convert image"

    /// Supported target UTIs. Callers pass `params["format"]` as one of
    /// "png" / "jpeg" / "heic" (case-insensitive).
    static let supportedFormats: Set<String> = ["png", "jpeg", "heic"]

    static func appliesTo(_ items: [BucketItem]) -> Bool {
        !items.isEmpty && items.allSatisfy { $0.kind == .image }
    }

    static func perform(_ items: [BucketItem], context: ActionContext) async throws -> [BucketItem] {
        guard !items.isEmpty else { throw QuickActionError.noInput }
        let format = (context.params["format"] ?? "jpeg").lowercased()
        guard supportedFormats.contains(format) else {
            throw QuickActionError.imageEncodeFailed
        }
        let quality = Double(context.params["quality"] ?? "0.85") ?? 0.85

        let targetUTI: String = {
            switch format {
            case "png":  return UTType.png.identifier
            case "heic": return UTType.heic.identifier
            default:     return UTType.jpeg.identifier
            }
        }()
        let targetExt: String = {
            switch format {
            case "png":  return "png"
            case "heic": return "heic"
            default:     return "jpg"
            }
        }()

        var out: [BucketItem] = []
        for item in items {
            try Task.checkCancellation()
            out.append(try await convert(
                item: item,
                targetUTI: targetUTI,
                targetExt: targetExt,
                quality: quality,
                format: format,
                context: context
            ))
        }
        return out
    }

    private static func convert(
        item: BucketItem,
        targetUTI: String,
        targetExt: String,
        quality: Double,
        format: String,
        context: ActionContext
    ) async throws -> BucketItem {
        guard let rel = item.fileRef?.cachedPath else {
            throw QuickActionError.missingFile(path: "<no cachedPath>")
        }
        let srcURL = context.storeRootURL.appendingPathComponent(rel)
        guard let data = try? Data(contentsOf: srcURL),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw QuickActionError.imageLoadFailed
        }

        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, targetUTI as CFString, 1, nil) else {
            throw QuickActionError.imageEncodeFailed
        }
        var props: [CFString: Any] = [:]
        if format == "jpeg" || format == "heic" {
            props[kCGImageDestinationLossyCompressionQuality] = quality
        }
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw QuickActionError.imageEncodeFailed
        }
        let outData = out as Data

        let newID = UUID()
        let relPath = try await context.store.writeSidecar(
            outData,
            bucketID: context.destinationBucketID,
            itemID: newID,
            subdir: "images",
            ext: targetExt
        )
        let displayName = makeDerivedName(
            original: item.fileRef?.displayName,
            suffix: ".\(targetExt)"
        )
        let fileRef = BucketItem.FileRef(
            originalPath: "",
            cachedPath: relPath,
            byteSize: Int64(outData.count),
            uti: targetUTI,
            displayName: displayName
        )
        return BucketItem(
            id: newID,
            kind: .image,
            sourceBundleID: item.sourceBundleID,
            fileRef: fileRef,
            derivedFromItemID: item.id,
            derivedAction: "convert:\(format)"
        )
    }
}

// MARK: - StripExifAction

/// Writes a copy of the image with all metadata stripped (EXIF, GPS, TIFF,
/// IPTC, XMP, …) — except orientation, which is baked into pixels via the
/// thumbnail transform so the visible result is identical.
///
/// Implemented by re-encoding with an empty metadata dictionary, which is
/// the canonical ImageIO way to drop everything.
enum StripExifAction: QuickAction {
    static let id = "strip-exif"
    static let title = "Strip metadata"

    static func appliesTo(_ items: [BucketItem]) -> Bool {
        !items.isEmpty && items.allSatisfy { $0.kind == .image }
    }

    static func perform(_ items: [BucketItem], context: ActionContext) async throws -> [BucketItem] {
        guard !items.isEmpty else { throw QuickActionError.noInput }
        var out: [BucketItem] = []
        for item in items {
            try Task.checkCancellation()
            out.append(try await strip(item: item, context: context))
        }
        return out
    }

    private static func strip(item: BucketItem, context: ActionContext) async throws -> BucketItem {
        guard let rel = item.fileRef?.cachedPath else {
            throw QuickActionError.missingFile(path: "<no cachedPath>")
        }
        let srcURL = context.storeRootURL.appendingPathComponent(rel)
        guard let data = try? Data(contentsOf: srcURL),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw QuickActionError.imageLoadFailed
        }
        let uti = (CGImageSourceGetType(source) as String?) ?? UTType.png.identifier

        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, uti as CFString, 1, nil) else {
            throw QuickActionError.imageEncodeFailed
        }
        // Explicit empty metadata dicts drop everything. We cannot simply
        // "not set" the properties because CGImageDestination would then
        // inherit them from the CGImage/CGImageSource.
        let cleanProps: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [:] as CFDictionary,
            kCGImagePropertyGPSDictionary: [:] as CFDictionary,
            kCGImagePropertyTIFFDictionary: [:] as CFDictionary,
            kCGImagePropertyIPTCDictionary: [:] as CFDictionary,
        ]
        CGImageDestinationAddImage(dest, cg, cleanProps as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw QuickActionError.imageEncodeFailed
        }
        let outData = out as Data

        let newID = UUID()
        let ext = UTType(uti)?.preferredFilenameExtension ?? "png"
        let relPath = try await context.store.writeSidecar(
            outData,
            bucketID: context.destinationBucketID,
            itemID: newID,
            subdir: "images",
            ext: ext
        )
        let displayName = makeDerivedName(
            original: item.fileRef?.displayName,
            suffix: "-clean"
        )
        let fileRef = BucketItem.FileRef(
            originalPath: "",
            cachedPath: relPath,
            byteSize: Int64(outData.count),
            uti: uti,
            displayName: displayName
        )
        return BucketItem(
            id: newID,
            kind: .image,
            sourceBundleID: item.sourceBundleID,
            fileRef: fileRef,
            derivedFromItemID: item.id,
            derivedAction: "stripExif"
        )
    }
}

// MARK: - Shared naming helper

/// Produces a sensible display name for a derived image:
///   - `"photo.jpg"` + suffix `"@50%"`  → `"photo@50%.jpg"`
///   - `"photo.jpg"` + suffix `".png"`  → `"photo.png"`
///   - `"photo.jpg"` + suffix `"-clean"` → `"photo-clean.jpg"`
///   - `nil`                             → `"derived"` + suffix
///
/// Kept internal so only Epic 07 actions consume it. Pure — tested without
/// any mocks.
func makeDerivedName(original: String?, suffix: String) -> String {
    guard let original, !original.isEmpty else {
        return "derived\(suffix)"
    }
    // Extension replace: suffix starts with "."
    if suffix.hasPrefix(".") {
        let newExt = String(suffix.dropFirst())
        let stem = (original as NSString).deletingPathExtension
        return "\(stem).\(newExt)"
    }
    // Infix insert before the existing extension.
    let stem = (original as NSString).deletingPathExtension
    let ext  = (original as NSString).pathExtension
    if ext.isEmpty {
        return "\(stem)\(suffix)"
    }
    return "\(stem)\(suffix).\(ext)"
}
