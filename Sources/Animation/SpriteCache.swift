import AppKit
import CoreGraphics

/// Caches extracted CGImage frames from sprite sheet PNGs.
/// Key: "pet/filename", Value: array of frames.
/// Thread-safety: accessed only from main thread (same as animation timer).
final class SpriteCache {
    static let shared = SpriteCache()

    private var cache: [String: [CGImage]] = [:]

    /// Returns cached frames, or loads + extracts from the sprite sheet PNG.
    func frames(pet: String, status: Status) -> [CGImage] {
        let cacheKey: String
        if SpriteConfig.isCustomPet(pet) {
            cacheKey = "\(pet)/\(status.rawValue)"
        } else {
            let info = SpriteConfig.sheet(pet: pet, status: status)
            cacheKey = "\(pet)/\(info.filename)"
        }

        if let cached = cache[cacheKey] {
            return cached
        }

        let info = SpriteConfig.sheet(pet: pet, status: status)

        let image: CGImage?
        if SpriteConfig.isCustomPet(pet) {
            image = loadCustomSpriteSheet(fileName: info.filename)
        } else {
            image = loadSpriteSheet(named: info.filename, subdirectory: info.subdirectory)
        }

        guard let image else { return [] }
        let extracted = extractFrames(from: image, info: info)
        cache[cacheKey] = extracted
        return extracted
    }

    func purge() {
        cache.removeAll()
    }

    func purgeCustomPet(_ petID: String) {
        cache = cache.filter { !$0.key.hasPrefix("\(petID)/") }
    }

    // MARK: - Private

    private func loadCustomSpriteSheet(fileName: String) -> CGImage? {
        let url = CustomOhhManager.shared.spritePath(fileName: fileName)
        return loadCGImage(from: url)
    }

    private func loadSpriteSheet(named name: String, subdirectory: String? = nil) -> CGImage? {
        let subdir = subdirectory.map { "Sprites/\($0)" } ?? "Sprites"
        if let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: subdir) {
            return loadCGImage(from: url)
        }
        if let url = Bundle.main.url(forResource: name, withExtension: "png") {
            return loadCGImage(from: url)
        }
        return nil
    }

    private func loadCGImage(from url: URL) -> CGImage? {
        guard let dataProvider = CGDataProvider(url: url as CFURL),
              let image = CGImage(
                  pngDataProviderSource: dataProvider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              ) else {
            return nil
        }
        return image
    }

    /// Extract frames from a sprite sheet using the sheet info.
    /// Supports rectangular frames and row selection for multi-direction sheets.
    private func extractFrames(from sheet: CGImage, info: SpriteSheetInfo) -> [CGImage] {
        var frames: [CGImage] = []
        frames.reserveCapacity(info.frames)

        let y = info.row * info.frameHeight
        for i in 0..<info.frames {
            let x = i * info.frameWidth
            let rect = CGRect(x: x, y: y, width: info.frameWidth, height: info.frameHeight)
            if let cropped = sheet.cropping(to: rect) {
                frames.append(cropped)
            }
        }
        return frames
    }
}
