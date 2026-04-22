import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Port of the TypeScript sprite sheet processor to Core Graphics.
///
/// Detects rows/columns of sprites in an arbitrary sprite sheet PNG,
/// removes background color, and packs selected frames into a grid
/// layout compatible with SpriteCache.
///
/// All operations are synchronous and CPU-bound; call from a background
/// queue when processing large sheets.
enum SmartImport {

    // MARK: - Constants

    static let frameSize = 128
    static let maxSheetWidth = 4096
    static let bgInnerTolerance: Double = 25.0     // ≤ this distance → fully transparent (bg removal)
    static let bgOuterTolerance: Double = 90.0     // ≥ this distance → fully opaque (bg removal)
    static let bgClusterTolerance: Double = 30.0   // corner-clustering in detectBgColor
    static let alphaThreshold: UInt8 = 10
    static let minGap = 5
    static let minRegionWidth = 10

    // MARK: - Types

    struct BgColor {
        let r: UInt8, g: UInt8, b: UInt8
    }

    struct DetectedRow {
        let index: Int
        let y1: Int
        let y2: Int
        var height: Int { y2 - y1 }
        let sprites: [SpriteRegion]
        var frameCount: Int { sprites.count }
    }

    struct SpriteRegion {
        var x1: Int
        var x2: Int
        var width: Int { x2 - x1 }
    }

    struct Frame {
        let index: Int
        let x1: Int
        let y1: Int
        let x2: Int
        let y2: Int
    }

    struct BBox {
        let x1: Int
        let y1: Int
        let x2: Int
        let y2: Int
    }

    struct GridLayout {
        let cols: Int
        let rows: Int
        let width: Int
        let height: Int
    }

    struct ProcessedStrip {
        let pngData: Data
        let frames: Int
    }

    // MARK: - Grid Layout

    static func gridLayout(frameCount: Int) -> GridLayout {
        let cols = max(1, maxSheetWidth / frameSize)
        let rows = max(1, (frameCount + cols - 1) / cols)
        return GridLayout(cols: cols, rows: rows, width: cols * frameSize, height: rows * frameSize)
    }

    // MARK: - Background Color Detection

    static func colorDistance(_ a: BgColor, _ b: BgColor) -> Double {
        let dr = Double(a.r) - Double(b.r)
        let dg = Double(a.g) - Double(b.g)
        let db = Double(a.b) - Double(b.b)
        return (dr * dr + dg * dg + db * db).squareRoot()
    }

    /// Detect dominant background color by sampling 4 corners.
    static func detectBgColor(pixels: UnsafePointer<UInt8>, width: Int, height: Int, bytesPerRow: Int) -> BgColor {
        func sample(x: Int, y: Int) -> BgColor {
            let offset = y * bytesPerRow + x * 4
            return BgColor(r: pixels[offset], g: pixels[offset + 1], b: pixels[offset + 2])
        }

        let corners = [
            sample(x: 1, y: 1),
            sample(x: width - 2, y: 1),
            sample(x: 1, y: height - 2),
            sample(x: width - 2, y: height - 2),
        ]

        var bestColor = corners[0]
        var bestCount = 0
        for candidate in corners {
            let count = corners.filter { colorDistance($0, candidate) <= bgClusterTolerance }.count
            if count > bestCount {
                bestCount = count
                bestColor = candidate
            }
        }
        return bestColor
    }

    // MARK: - Background Removal

    /// Removes background pixels (within tolerance of bgColor) by setting alpha to 0.
    /// Returns a new RGBA bitmap context with straight (non-premultiplied) alpha.
    static func removeBackground(
        from image: CGImage,
        bgColor: BgColor? = nil
    ) -> (context: CGContext, bgColor: BgColor)? {
        let w = image.width
        let h = image.height
        // Reject images too small for 4-corner sampling
        guard w >= 3, h >= 3 else { return nil }
        guard let ctx = createRGBAContext(width: w, height: h) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        guard let data = ctx.data else { return nil }
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = ctx.bytesPerRow

        let detected = bgColor ?? detectBgColor(pixels: pixels, width: w, height: h, bytesPerRow: bytesPerRow)

        let inner = bgInnerTolerance
        let outer = bgOuterTolerance
        let bandWidth = outer - inner

        for y in 0..<h {
            for x in 0..<w {
                let offset = y * bytesPerRow + x * 4
                let r = pixels[offset]
                let g = pixels[offset + 1]
                let b = pixels[offset + 2]
                let px = BgColor(r: r, g: g, b: b)
                let d = colorDistance(px, detected)

                if d <= inner {
                    pixels[offset]     = 0
                    pixels[offset + 1] = 0
                    pixels[offset + 2] = 0
                    pixels[offset + 3] = 0
                    continue
                }

                if d >= outer {
                    // Fully sprite — leave pixel as-is. Source is opaque
                    // after ctx.draw onto a fresh RGBA context.
                    continue
                }

                // Transition band: scale alpha linearly with distance past
                // inner, then back out the bg contribution from the observed
                // color (standard keying "spill removal").
                let t = (d - inner) / bandWidth                  // 0..1
                let a = UInt8(max(0.0, min(255.0, (t * 255.0).rounded())))
                let alphaF = Double(a) / 255.0

                // observed = alphaF * fg + (1 - alphaF) * bg
                //   =>  fg = (observed - (1 - alphaF) * bg) / alphaF
                let invA = 1.0 - alphaF
                let fgR = (Double(r) - invA * Double(detected.r)) / alphaF
                let fgG = (Double(g) - invA * Double(detected.g)) / alphaF
                let fgB = (Double(b) - invA * Double(detected.b)) / alphaF

                let clampedR = max(0.0, min(255.0, fgR))
                let clampedG = max(0.0, min(255.0, fgG))
                let clampedB = max(0.0, min(255.0, fgB))

                // Context is premultipliedLast — write premultiplied channels.
                pixels[offset]     = UInt8((clampedR * alphaF).rounded())
                pixels[offset + 1] = UInt8((clampedG * alphaF).rounded())
                pixels[offset + 2] = UInt8((clampedB * alphaF).rounded())
                pixels[offset + 3] = a
            }
        }

        return (ctx, detected)
    }

    // MARK: - Row Detection

    /// Detect rows by finding horizontal transparent gaps.
    static func detectRows(pixels: UnsafePointer<UInt8>, width: Int, height: Int, bytesPerRow: Int) -> [DetectedRow] {
        var rows: [DetectedRow] = []
        var inContent = false
        var rowStart = 0

        for y in 0..<height {
            var hasContent = false
            let rowBase = y * bytesPerRow
            for x in 0..<width {
                let alpha = pixels[rowBase + x * 4 + 3]
                if alpha > alphaThreshold {
                    hasContent = true
                    break
                }
            }

            if hasContent && !inContent {
                rowStart = y
                inContent = true
            } else if !hasContent && inContent {
                let sprites = detectColumns(pixels: pixels, width: width, bytesPerRow: bytesPerRow, y1: rowStart, y2: y)
                rows.append(DetectedRow(index: rows.count, y1: rowStart, y2: y, sprites: sprites))
                inContent = false
            }
        }

        if inContent {
            let sprites = detectColumns(pixels: pixels, width: width, bytesPerRow: bytesPerRow, y1: rowStart, y2: height)
            rows.append(DetectedRow(index: rows.count, y1: rowStart, y2: height, sprites: sprites))
        }

        return rows
    }

    // MARK: - Column Detection

    /// Detect individual sprite columns within a row.
    /// Pass 1: raw content regions. Pass 2: bridge tiny gaps. Pass 3: absorb slivers.
    static func detectColumns(pixels: UnsafePointer<UInt8>, width: Int, bytesPerRow: Int, y1: Int, y2: Int) -> [SpriteRegion] {
        // Pass 1: detect raw content regions
        var raw: [(x1: Int, x2: Int)] = []
        var inContent = false
        var colStart = 0

        for x in 0..<width {
            var hasContent = false
            for y in y1..<y2 {
                let alpha = pixels[y * bytesPerRow + x * 4 + 3]
                if alpha > alphaThreshold {
                    hasContent = true
                    break
                }
            }

            if hasContent && !inContent {
                colStart = x
                inContent = true
            } else if !hasContent && inContent {
                raw.append((colStart, x))
                inContent = false
            }
        }
        if inContent {
            raw.append((colStart, width))
        }

        guard !raw.isEmpty else { return [] }

        // Pass 2: bridge gaps smaller than minGap
        var merged: [(x1: Int, x2: Int)] = [raw[0]]
        for i in 1..<raw.count {
            let gap = raw[i].x1 - merged[merged.count - 1].x2
            if gap < minGap {
                merged[merged.count - 1].x2 = raw[i].x2
            } else {
                merged.append(raw[i])
            }
        }

        // Pass 3: absorb narrow slivers
        var changed = true
        while changed {
            changed = false
            for i in 0..<merged.count {
                let regionWidth = merged[i].x2 - merged[i].x1
                if regionWidth < minRegionWidth && merged.count > 1 {
                    if i == 0 {
                        merged[1].x1 = merged[i].x1
                    } else if i == merged.count - 1 {
                        merged[i - 1].x2 = merged[i].x2
                    } else {
                        let gapLeft = merged[i].x1 - merged[i - 1].x2
                        let gapRight = merged[i + 1].x1 - merged[i].x2
                        if gapLeft <= gapRight {
                            merged[i - 1].x2 = merged[i].x2
                        } else {
                            merged[i + 1].x1 = merged[i].x1
                        }
                    }
                    merged.remove(at: i)
                    changed = true
                    break
                }
            }
        }

        return merged.map { SpriteRegion(x1: $0.x1, x2: $0.x2) }
    }

    // MARK: - Frame Extraction

    /// Flatten all detected rows into a numbered list of frames.
    static func extractFrames(from rows: [DetectedRow]) -> [Frame] {
        var frames: [Frame] = []
        for row in rows {
            for col in row.sprites {
                frames.append(Frame(index: frames.count, x1: col.x1, y1: row.y1, x2: col.x2, y2: row.y2))
            }
        }
        return frames
    }

    // MARK: - Tight Bounding Box

    /// Find the tight bounding box of non-transparent pixels in an RGBA region.
    static func getTightBBox(
        pixels: UnsafePointer<UInt8>,
        bytesPerRow: Int,
        x: Int, y: Int,
        width: Int, height: Int
    ) -> BBox? {
        var minX = width, minY = height, maxX = 0, maxY = 0
        var found = false

        for dy in 0..<height {
            for dx in 0..<width {
                let alpha = pixels[(y + dy) * bytesPerRow + (x + dx) * 4 + 3]
                if alpha > alphaThreshold {
                    if dx < minX { minX = dx }
                    if dx > maxX { maxX = dx }
                    if dy < minY { minY = dy }
                    if dy > maxY { maxY = dy }
                    found = true
                }
            }
        }

        return found ? BBox(x1: minX, y1: minY, x2: maxX + 1, y2: maxY + 1) : nil
    }

    // MARK: - Strip Creation

    /// Create a sprite strip from specific frame indices, packed into a grid.
    /// The output context uses top-left origin (flipped) so frames map correctly
    /// to SpriteCache's CGImage.cropping extraction.
    static func createStripFromFrames(
        context: CGContext,
        frames: [Frame],
        indices: [Int]
    ) -> ProcessedStrip? {
        let selected = indices.compactMap { i -> Frame? in
            i >= 0 && i < frames.count ? frames[i] : nil
        }
        guard !selected.isEmpty else { return nil }

        guard let srcData = context.data else { return nil }
        let srcPixels = srcData.assumingMemoryBound(to: UInt8.self)
        let srcBytesPerRow = context.bytesPerRow

        // Compute all bounding boxes BEFORE makeImage() to avoid dangling pointer.
        // srcPixels is only valid while the context's data buffer is not invalidated.
        struct FrameInfo {
            let frame: Frame
            let bbox: BBox
        }
        var frameInfos: [FrameInfo] = []
        for frame in selected {
            let sw = frame.x2 - frame.x1
            let sh = frame.y2 - frame.y1
            guard let bbox = getTightBBox(
                pixels: srcPixels, bytesPerRow: srcBytesPerRow,
                x: frame.x1, y: frame.y1,
                width: sw, height: sh
            ) else { continue }
            let cropW = bbox.x2 - bbox.x1
            let cropH = bbox.y2 - bbox.y1
            guard cropW > 0, cropH > 0 else { continue }
            frameInfos.append(FrameInfo(frame: frame, bbox: bbox))
        }
        guard !frameInfos.isEmpty else { return nil }

        // Now safe to snapshot — we no longer need the raw pixel pointer
        guard let srcImage = context.makeImage() else { return nil }

        let layout = gridLayout(frameCount: frameInfos.count)
        guard let stripCtx = createRGBAContext(width: layout.width, height: layout.height) else { return nil }

        // Leave stripCtx's CTM at default (bottom-left origin). A previous
        // implementation pre-flipped with translate+scale(1, -1) hoping to
        // get top-left drawing coords, but `ctx.draw(image, in:)` respects
        // the CTM — under a y-flip, the image itself is drawn vertically
        // MIRRORED. That turned every v2-imported ohh upside down. We now
        // compute `drawY` in bottom-up coords so the memory layout matches
        // the top-left convention SpriteCache expects without any CTM games.
        for (i, info) in frameInfos.enumerated() {
            let bbox = info.bbox
            let cropW = bbox.x2 - bbox.x1
            let cropH = bbox.y2 - bbox.y1

            let scale = min(Double(frameSize) / Double(cropW), Double(frameSize) / Double(cropH))
            let scaledW = Int((Double(cropW) * scale).rounded())
            let scaledH = Int((Double(cropH) * scale).rounded())
            let ox = Int((Double(frameSize - scaledW) / 2.0).rounded())
            let oy = Int((Double(frameSize - scaledH) / 2.0).rounded())

            // Cell position using top-left convention (matches SpriteCache).
            let cellX = (i % layout.cols) * frameSize
            let cellYTopDown = (i / layout.cols) * frameSize
            // Convert to bottom-up CG y of the draw rect's origin.
            let drawY = layout.height - cellYTopDown - oy - scaledH

            // getTightBBox + CGImage.cropping both use top-left coords on the
            // source image. No CTM involved here.
            let srcRect = CGRect(
                x: info.frame.x1 + bbox.x1,
                y: info.frame.y1 + bbox.y1,
                width: cropW,
                height: cropH
            )
            guard let cropped = srcImage.cropping(to: srcRect) else { continue }

            stripCtx.interpolationQuality = .high
            stripCtx.draw(
                cropped,
                in: CGRect(x: cellX + ox, y: drawY, width: scaledW, height: scaledH)
            )
        }

        guard let stripImage = stripCtx.makeImage(),
              let pngData = pngData(from: stripImage) else { return nil }

        return ProcessedStrip(pngData: pngData, frames: frameInfos.count)
    }

    // MARK: - Frame Input Parsing

    /// Parse user input like "1-5" or "5,1,3" into 0-based indices.
    /// Preserves the order the user wrote (so animation order follows the input),
    /// with first-occurrence-wins dedup.
    static func parseFrameInput(_ input: String, maxFrames: Int) -> [Int] {
        var seen: Set<Int> = []
        var result: [Int] = []
        let parts = input.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }

        for part in parts {
            if part.contains("-") {
                let range = part.split(separator: "-").compactMap { Int($0) }
                if range.count == 2 {
                    let start = max(1, range[0])
                    let end = min(maxFrames, range[1])
                    guard start <= end else { continue }
                    for i in start...end {
                        let idx = i - 1
                        if seen.insert(idx).inserted { result.append(idx) }
                    }
                }
            } else if let n = Int(part), n >= 1, n <= maxFrames {
                let idx = n - 1
                if seen.insert(idx).inserted { result.append(idx) }
            }
        }

        return result
    }

    // MARK: - Full Pipeline

    /// Process a sprite sheet: detect background, remove it, detect rows/frames.
    /// Returns the processed context and detected frames.
    static func processSheet(image: CGImage) -> (context: CGContext, frames: [Frame], rows: [DetectedRow], bgColor: BgColor)? {
        guard let result = removeBackground(from: image) else { return nil }
        let ctx = result.context
        let w = ctx.width
        let h = ctx.height
        let bytesPerRow = ctx.bytesPerRow

        guard let data = ctx.data else { return nil }
        let pixels = data.assumingMemoryBound(to: UInt8.self)

        let rows = detectRows(pixels: pixels, width: w, height: h, bytesPerRow: bytesPerRow)
        let frames = extractFrames(from: rows)

        return (ctx, frames, rows, result.bgColor)
    }

    // MARK: - Image I/O Helpers

    /// Load a CGImage from a file URL.
    static func loadImage(from url: URL) -> CGImage? {
        guard let provider = CGDataProvider(url: url as CFURL) else { return nil }
        // Try PNG first, then fall back to ImageIO for other formats
        if let image = CGImage(pngDataProviderSource: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) {
            return image
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Load a CGImage from raw Data.
    static func loadImage(from data: Data) -> CGImage? {
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        if let image = CGImage(pngDataProviderSource: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) {
            return image
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Create an RGBA bitmap context with premultiplied alpha.
    /// Background pixels are fully opaque (alpha=255) so premultiplied == straight for comparison.
    /// When making pixels transparent, set all 4 bytes to 0 (correct for premultiplied format).
    /// bytesPerRow=0 lets CG choose optimal stride; callers use ctx.bytesPerRow for pixel math.
    static func createRGBAContext(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    /// Export a CGImage as PNG Data.
    static func pngData(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
