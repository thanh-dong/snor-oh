import AppKit

/// Process-wide NSImage cache keyed by absolute file path.
///
/// Problem this solves: `BucketCardView` is re-created on every tab switch
/// (different `BucketManager.activeBucket` → different items in the LazyVStack),
/// and its thumbnail code used to call `NSImage(contentsOf:)` directly from
/// the view body. With a dozen images in a bucket and a dozen buckets,
/// switching tabs triggered ~144 disk reads per render, each doing PNG/HEIC
/// decode in the middle of the UI update. Palpable lag on selection.
///
/// Fix: cache the decoded NSImage keyed by its on-disk path. First render
/// pays the I/O cost once, every subsequent render is a dictionary lookup.
/// `NSCache` is used so macOS can evict entries under memory pressure —
/// no manual trimming required.
///
/// The cache is *not* invalidated on writes: sidecar files are stored at
/// UUID-based paths (`<bucketID>/images/<itemID>.<ext>`) that are unique to
/// each item version, so an edited image gets a new path and bypasses any
/// stale entry. The only edge case is quick-action overwrites which reuse
/// the same item id — those call `invalidate(path:)` explicitly.
final class BucketImageCache {

    static let shared = BucketImageCache()

    /// NSCache handles its own thread-safety, so callers can hit this from
    /// any queue. Keyed by `URL.path` as `NSString` because `NSCache`'s keys
    /// must be objc-bridged.
    private let cache: NSCache<NSString, NSImage>

    private init() {
        let c = NSCache<NSString, NSImage>()
        // Generous ceiling: 256 images. Real bucket UX rarely breaches 200,
        // and the LRU eviction here is cheap.
        c.countLimit = 256
        // ~64 MB of decoded pixels. Rough guard — NSCache counts by
        // `totalCostLimit` only when callers pass a cost, which we do.
        c.totalCostLimit = 64 * 1024 * 1024
        self.cache = c
    }

    /// Returns a cached image for the given absolute URL, loading + caching
    /// it on first miss. Returns nil when the file is unreadable.
    func image(for url: URL) -> NSImage? {
        let key = url.path as NSString
        if let hit = cache.object(forKey: key) {
            return hit
        }
        guard let img = NSImage(contentsOf: url) else { return nil }
        // Estimate decoded pixel cost: width × height × 4 bytes. Fallback
        // to the bitmap representation's size for non-bitmap images.
        let cost: Int
        if let rep = img.representations.first as? NSBitmapImageRep {
            cost = rep.pixelsWide * rep.pixelsHigh * 4
        } else {
            cost = Int(img.size.width * img.size.height * 4)
        }
        cache.setObject(img, forKey: key, cost: cost)
        return img
    }

    /// Drop a cache entry — used when the underlying file is overwritten
    /// (e.g. a quick-action that replaces its own sidecar).
    func invalidate(path: String) {
        cache.removeObject(forKey: path as NSString)
    }

    /// Purge everything. Used by tests and by `deleteBucket` when a whole
    /// sidecar tree disappears.
    func purgeAll() {
        cache.removeAllObjects()
    }
}
