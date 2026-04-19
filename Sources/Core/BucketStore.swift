import Foundation

/// Owns on-disk state for the Bucket feature — manifest JSON + sidecar files.
///
/// Layout (v1, single-bucket; Epic 04 bumps to v2 schema):
/// ```
/// <rootURL>/
/// ├── manifest.json          # Bucket JSON
/// ├── settings.json          # BucketSettings JSON
/// ├── files/<itemID>.<ext>   # dropped file copies
/// ├── images/<itemID>.png    # screenshot + image copies
/// ├── favicons/<itemID>.ico  # URL favicons
/// └── og/<itemID>.jpg        # URL og:image
/// ```
///
/// All disk I/O goes through this actor so the @MainActor `BucketManager`
/// never blocks the UI thread.
actor BucketStore {

    let rootURL: URL

    /// Default production root: `~/.snor-oh/buckets/`.
    /// Tests should inject a temp directory.
    init(rootURL: URL? = nil) {
        if let rootURL {
            self.rootURL = rootURL
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            self.rootURL = home
                .appendingPathComponent(".snor-oh")
                .appendingPathComponent("buckets")
        }
    }

    // MARK: - Manifest

    /// Loads the persisted bucket. If no manifest exists, returns a fresh
    /// empty `Bucket(name: "Default")` (caller decides whether to persist it).
    func loadBucket() throws -> Bucket {
        try ensureDirectories()
        let url = manifestURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            return Bucket(name: "Default")
        }
        let data = try Data(contentsOf: url)
        return try decoder.decode(Bucket.self, from: data)
    }

    /// Atomically persists the bucket.
    func saveBucket(_ bucket: Bucket) throws {
        try ensureDirectories()
        let data = try encoder.encode(bucket)
        try atomicWrite(data, to: manifestURL)
    }

    // MARK: - Settings

    func loadSettings() throws -> BucketSettings {
        try ensureDirectories()
        let url = settingsURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            return BucketSettings()
        }
        let data = try Data(contentsOf: url)
        return try decoder.decode(BucketSettings.self, from: data)
    }

    func saveSettings(_ settings: BucketSettings) throws {
        try ensureDirectories()
        let data = try encoder.encode(settings)
        try atomicWrite(data, to: settingsURL)
    }

    // MARK: - Sidecars

    /// Copies `source` into the bucket's sidecar directory under the given subdir
    /// (e.g. `"files"`, `"images"`, `"favicons"`, `"og"`). Returns the path
    /// relative to `rootURL` — that's what gets stored on `BucketItem.fileRef.cachedPath`.
    ///
    /// If `move: true`, the source is renamed (FS-rename); cross-volume moves
    /// automatically fall back to copy+delete.
    func copySidecar(
        from source: URL,
        itemID: UUID,
        subdir: String,
        ext: String? = nil,
        move: Bool = false
    ) throws -> String {
        try ensureDirectories()
        let subdirURL = rootURL.appendingPathComponent(subdir)
        try FileManager.default.createDirectory(at: subdirURL, withIntermediateDirectories: true)

        let resolvedExt = ext ?? source.pathExtension
        let fileName = resolvedExt.isEmpty
            ? itemID.uuidString
            : "\(itemID.uuidString).\(resolvedExt)"
        let dest = subdirURL.appendingPathComponent(fileName)

        // If dest exists (crash recovery), remove it first — itemID is unique enough
        // that we prefer the caller's new bytes.
        try? FileManager.default.removeItem(at: dest)

        if move {
            do {
                try FileManager.default.moveItem(at: source, to: dest)
            } catch {
                // Cross-volume or permission — fall back to copy+delete.
                try FileManager.default.copyItem(at: source, to: dest)
                try? FileManager.default.removeItem(at: source)
            }
        } else {
            try FileManager.default.copyItem(at: source, to: dest)
        }

        return "\(subdir)/\(fileName)"
    }

    /// Writes raw bytes (e.g. clipboard image data) to a sidecar and returns the relative path.
    func writeSidecar(
        _ data: Data,
        itemID: UUID,
        subdir: String,
        ext: String
    ) throws -> String {
        try ensureDirectories()
        let subdirURL = rootURL.appendingPathComponent(subdir)
        try FileManager.default.createDirectory(at: subdirURL, withIntermediateDirectories: true)

        let fileName = "\(itemID.uuidString).\(ext)"
        let dest = subdirURL.appendingPathComponent(fileName)
        try atomicWrite(data, to: dest)
        return "\(subdir)/\(fileName)"
    }

    /// Removes sidecar files for evicted items. Relative paths are resolved
    /// against `rootURL`. Missing paths are ignored (idempotent).
    func deleteSidecars(relativePaths: [String]) {
        for rel in relativePaths {
            let url = rootURL.appendingPathComponent(rel)
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Resolves a relative sidecar path back to an absolute URL.
    nonisolated func absoluteURL(forRelative relativePath: String) -> URL {
        rootURL.appendingPathComponent(relativePath)
    }

    /// Total sidecar storage on disk in bytes — used by BucketManager for
    /// size-based LRU eviction.
    func sidecarStorageBytes() -> Int64 {
        let fm = FileManager.default
        var total: Int64 = 0
        let subdirs = ["files", "images", "favicons", "og"]
        for sub in subdirs {
            let subURL = rootURL.appendingPathComponent(sub)
            guard let e = fm.enumerator(at: subURL, includingPropertiesForKeys: [.fileSizeKey]) else {
                continue
            }
            for case let url as URL in e {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                total += Int64(size)
            }
        }
        return total
    }

    // MARK: - Private

    private var manifestURL: URL { rootURL.appendingPathComponent("manifest.json") }
    private var settingsURL: URL { rootURL.appendingPathComponent("settings.json") }

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private func ensureDirectories() throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    private func atomicWrite(_ data: Data, to url: URL) throws {
        let tmp = url.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        // replaceItemAt handles the case where `url` doesn't yet exist.
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: url)
        }
    }
}
