import Foundation
import AppKit
import UniformTypeIdentifiers
import CryptoKit

/// Core state holder for the Bucket feature.
///
/// Runs on `@MainActor` because SwiftUI observes its state. Disk I/O is
/// delegated to a `BucketStore` actor so the UI thread never blocks.
///
/// Lifecycle mirrors `CustomOhhManager`:
///  1. `AppDelegate.applicationDidFinishLaunching` calls `.shared.load()`.
///  2. UI reads `activeBucket` / `settings` via `@Observable`.
///  3. Mutations (`add`, `remove`, `togglePin`, …) update state synchronously,
///     post `.bucketChanged`, and schedule a debounced persist.
@Observable
@MainActor
final class BucketManager {

    // MARK: - Singleton

    static let shared = BucketManager()

    // MARK: - State

    private(set) var activeBucket: Bucket = Bucket(name: "Default")
    private(set) var settings: BucketSettings = BucketSettings()

    /// Present-only-in-tests hook to wait on the pending persist debounce.
    /// Production callers should never need this.
    var persistInFlight: Task<Void, Never>?

    // MARK: - Private

    private let store: BucketStore
    private var loaded = false
    private var persistDebounce: Task<Void, Never>?

    /// The root of on-disk bucket storage — exposed so views can resolve
    /// sidecar thumbnails without awaiting the store actor. Captured at init.
    nonisolated let storeRootURL: URL

    // MARK: - Init

    /// Designated init. Production uses `.shared`; tests construct their own
    /// with an isolated temp-dir `BucketStore`.
    init(store: BucketStore = BucketStore()) {
        self.store = store
        self.storeRootURL = store.rootURL
    }

    // MARK: - Lifecycle

    /// Called from `AppDelegate` at launch. Synchronous fire-and-forget —
    /// UI renders the default empty bucket until disk load resolves.
    func load() {
        guard !loaded else { return }
        loaded = true
        Task { [weak self] in
            await self?.loadAsync()
        }
    }

    private func loadAsync() async {
        do {
            let b = try await store.loadBucket()
            let s = try await store.loadSettings()
            self.activeBucket = b
            self.settings = s
        } catch {
            NSLog("[bucket] load failed: \(error)")
        }
    }

    // MARK: - Mutations

    /// Inserts an item at the head (newest-first), fires `.bucketChanged`,
    /// enforces LRU caps, schedules a persist.
    ///
    /// **Dedupe semantics**: if an equivalent item already exists anywhere in
    /// the bucket (not just at the head), the existing item is *promoted*
    /// to the top with a refreshed `lastAccessedAt` — no duplicate is added.
    /// This handles both the "⌘C same thing twice" and the "drag same file
    /// twice" cases without bloating the bucket.
    func add(_ item: BucketItem, source: BucketChangeSource) {
        if let existingIdx = duplicateIndex(of: item) {
            promoteExisting(at: existingIdx, source: source)
            return
        }
        activeBucket.items.insert(item, at: 0)
        evictIfNeeded()
        postChanged(change: .added, source: source, itemID: item.id)
        schedulePersist()
    }

    /// Moves the item at `idx` to the head of the bucket and refreshes
    /// `lastAccessedAt`. Used for dedup hits — user sees the existing item
    /// re-surface at the top of the list.
    private func promoteExisting(at idx: Int, source: BucketChangeSource) {
        var existing = activeBucket.items.remove(at: idx)
        existing.lastAccessedAt = Date()
        activeBucket.items.insert(existing, at: 0)
        postChanged(change: .added, source: source, itemID: existing.id)
        schedulePersist()
    }

    /// Async entry point for file drops. Copies the source into the sidecar
    /// directory **before** inserting, so the item's `cachedPath` is populated
    /// and the bucket survives restart.
    ///
    /// Dedupes by `originalPath` *before* the sidecar copy — so re-dragging
    /// the same file is a cheap no-op (no redundant disk I/O).
    func add(fileAt url: URL, source: BucketChangeSource, stackGroupID: UUID? = nil) async {
        // Cheap path-based dedupe — no sidecar copy needed on a hit.
        if let idx = activeBucket.items.firstIndex(where: { existing in
            guard existing.kind == .file || existing.kind == .folder || existing.kind == .image,
                  let p = existing.fileRef?.originalPath, !p.isEmpty else { return false }
            return p == url.path
        }) {
            promoteExisting(at: idx, source: source)
            return
        }

        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        let kind = classifyFile(url: url, isDirectory: isDir.boolValue)
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        let uti = (try? url.resourceValues(forKeys: [.typeIdentifierKey]).typeIdentifier)
            ?? (isDir.boolValue ? "public.folder" : "public.data")

        let itemID = UUID()
        var cachedPath: String? = nil
        if !isDir.boolValue {
            let subdir = kind == .image ? "images" : "files"
            cachedPath = try? await store.copySidecar(
                from: url,
                itemID: itemID,
                subdir: subdir
            )
        }

        let item = BucketItem(
            id: itemID,
            kind: kind,
            stackGroupID: stackGroupID,
            fileRef: .init(
                originalPath: url.path,
                cachedPath: cachedPath,
                byteSize: size,
                uti: uti,
                displayName: url.lastPathComponent
            )
        )
        add(item, source: source)
    }

    /// Async entry point for raw image bytes (pasteboard image drops).
    /// Writes the PNG bytes into the sidecar and inserts with `cachedPath` set.
    ///
    /// Dedupes by SHA-256 content hash *before* the sidecar write — so
    /// re-copying the same image is a cheap no-op that just re-surfaces the
    /// existing item.
    func add(imageData data: Data, source: BucketChangeSource, stackGroupID: UUID? = nil) async {
        let hash = sha256Hex(data)

        if let idx = activeBucket.items.firstIndex(where: { $0.contentHash == hash }) {
            promoteExisting(at: idx, source: source)
            return
        }

        let itemID = UUID()
        let cachedPath = try? await store.writeSidecar(
            data,
            itemID: itemID,
            subdir: "images",
            ext: "png"
        )
        let item = BucketItem(
            id: itemID,
            kind: .image,
            stackGroupID: stackGroupID,
            contentHash: hash,
            fileRef: .init(
                originalPath: "",
                cachedPath: cachedPath,
                byteSize: Int64(data.count),
                uti: "public.png",
                displayName: "image-\(itemID.uuidString.prefix(8)).png"
            )
        )
        add(item, source: source)
    }

    private func classifyFile(url: URL, isDirectory: Bool) -> BucketItemKind {
        if isDirectory { return .folder }
        if let uti = (try? url.resourceValues(forKeys: [.typeIdentifierKey]).typeIdentifier),
           let t = UTType(uti), t.conforms(to: .image) {
            return .image
        }
        return .file
    }

    /// Removes by ID; deletes any sidecar files.
    /// `source` defaults to `.panel` since most callers are UI-driven, but can
    /// be overridden (e.g. from peer-sync or watched-folder cleanup in later
    /// epics) so Epic 02's catch reaction picks the right intensity.
    func remove(id: UUID, source: BucketChangeSource = .panel) {
        guard let idx = activeBucket.items.firstIndex(where: { $0.id == id }) else { return }
        let removed = activeBucket.items.remove(at: idx)
        cleanupSidecars(for: [removed])
        postChanged(change: .removed, source: source, itemID: id)
        schedulePersist()
    }

    /// Toggles `pinned`; pinned items are never auto-evicted and never
    /// removed by `clearUnpinned()`.
    func togglePin(id: UUID, source: BucketChangeSource = .panel) {
        guard let idx = activeBucket.items.firstIndex(where: { $0.id == id }) else { return }
        activeBucket.items[idx].pinned.toggle()
        let kind: BucketChangeKind = activeBucket.items[idx].pinned ? .pinned : .unpinned
        postChanged(change: kind, source: source, itemID: id)
        schedulePersist()
    }

    /// Removes all unpinned items and their sidecars.
    func clearUnpinned(source: BucketChangeSource = .panel) {
        let removed = activeBucket.items.filter { !$0.pinned }
        guard !removed.isEmpty else { return }
        activeBucket.items.removeAll { !$0.pinned }
        cleanupSidecars(for: removed)
        postChanged(change: .cleared, source: source, itemID: nil)
        schedulePersist()
    }

    /// Fuzzy-ish filter across text, URL string, URL title, file display name,
    /// and `sourceBundleID`. Case-insensitive, no ranking.
    func search(_ query: String) -> [BucketItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return activeBucket.items }
        let needle = q.lowercased()
        return activeBucket.items.filter { item in
            if item.text?.lowercased().contains(needle) == true { return true }
            if item.urlMeta?.urlString.lowercased().contains(needle) == true { return true }
            if item.urlMeta?.title?.lowercased().contains(needle) == true { return true }
            if item.fileRef?.displayName.lowercased().contains(needle) == true { return true }
            if item.sourceBundleID?.lowercased().contains(needle) == true { return true }
            return false
        }
    }

    // MARK: - Settings

    func updateSettings(_ new: BucketSettings) {
        self.settings = new
        evictIfNeeded()
        Task { [store] in
            try? await store.saveSettings(new)
        }
    }

    // MARK: - Dedupe helper

    /// Returns the index of an existing item that is "the same" as
    /// `candidate`, or nil if there's no match. The scan is across the whole
    /// bucket — not just the head — so a non-adjacent duplicate (user ⌘C'd
    /// A, then B, then A) resolves to a hit on the first A.
    ///
    /// Match rules (kinds must agree):
    ///   - `.text` / `.richText`: payloads equal.
    ///   - `.url`: URL strings equal.
    ///   - `.color`: hex strings equal.
    ///   - `.file` / `.folder`: either same `originalPath` or same
    ///     `contentHash` (if both sides computed one).
    ///   - `.image`: same `contentHash`.
    ///
    /// Files are *not* hashed on drop — path equality catches the common
    /// "drag the same file twice" case cheaply. Images *are* hashed
    /// (done in `add(imageData:)`) since there's no path to compare.
    private func duplicateIndex(of candidate: BucketItem) -> Int? {
        activeBucket.items.firstIndex { existing in
            guard existing.kind == candidate.kind else { return false }
            switch candidate.kind {
            case .text, .richText:
                return !(candidate.text ?? "").isEmpty
                    && existing.text == candidate.text
            case .url:
                return !(candidate.urlMeta?.urlString ?? "").isEmpty
                    && existing.urlMeta?.urlString == candidate.urlMeta?.urlString
            case .color:
                return !(candidate.colorHex ?? "").isEmpty
                    && existing.colorHex == candidate.colorHex
            case .file, .folder:
                if let a = candidate.fileRef?.originalPath, !a.isEmpty,
                   let b = existing.fileRef?.originalPath, !b.isEmpty,
                   a == b { return true }
                if let a = candidate.contentHash, let b = existing.contentHash {
                    return a == b
                }
                return false
            case .image:
                if let a = candidate.contentHash, let b = existing.contentHash {
                    return a == b
                }
                return false
            }
        }
    }

    private func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    // MARK: - LRU eviction

    /// Enforces `maxItems` and `maxStorageBytes`. Pinned items are spared.
    /// Only runs if caps are exceeded.
    private func evictIfNeeded() {
        // 1. Count cap: drop oldest unpinned until under cap.
        if activeBucket.items.count > settings.maxItems {
            evictOldestUnpinned(toCount: settings.maxItems)
        }
        // 2. Size cap: quick heuristic — sum cached sidecar sizes from item metadata.
        //    (Full on-disk audit lives in BucketStore and runs only on demand.)
        let approxSize = activeBucket.items.reduce(Int64(0)) { acc, item in
            acc + (item.fileRef?.byteSize ?? 0)
        }
        if approxSize > settings.maxStorageBytes {
            evictOldestUnpinnedBySize(target: settings.maxStorageBytes)
        }
    }

    private func evictOldestUnpinned(toCount maxCount: Int) {
        // Items are newest-first; oldest at the tail.
        var removed: [BucketItem] = []
        while activeBucket.items.count > maxCount {
            // Find last unpinned (oldest). If none, stop.
            guard let lastUnpinnedIdx = activeBucket.items.lastIndex(where: { !$0.pinned }) else {
                break
            }
            removed.append(activeBucket.items.remove(at: lastUnpinnedIdx))
        }
        if !removed.isEmpty {
            cleanupSidecars(for: removed)
        }
    }

    private func evictOldestUnpinnedBySize(target: Int64) {
        var removed: [BucketItem] = []
        var size = activeBucket.items.reduce(Int64(0)) { $0 + ($1.fileRef?.byteSize ?? 0) }
        while size > target {
            guard let idx = activeBucket.items.lastIndex(where: { !$0.pinned }) else { break }
            let item = activeBucket.items.remove(at: idx)
            size -= item.fileRef?.byteSize ?? 0
            removed.append(item)
        }
        if !removed.isEmpty {
            cleanupSidecars(for: removed)
        }
    }

    private func cleanupSidecars(for items: [BucketItem]) {
        var paths: [String] = []
        for item in items {
            if let p = item.fileRef?.cachedPath { paths.append(p) }
            if let p = item.urlMeta?.faviconPath { paths.append(p) }
            if let p = item.urlMeta?.ogImagePath { paths.append(p) }
        }
        guard !paths.isEmpty else { return }
        Task { [store] in
            await store.deleteSidecars(relativePaths: paths)
        }
    }

    // MARK: - Notifications

    private func postChanged(change: BucketChangeKind, source: BucketChangeSource, itemID: UUID?) {
        var info: [String: Any] = [
            "change": change.rawValue,
            "source": source.rawValue,
        ]
        if let itemID {
            info["itemID"] = itemID
        }
        NotificationCenter.default.post(
            name: .bucketChanged,
            object: nil,
            userInfo: info
        )
    }

    // MARK: - Persist debounce

    /// Coalesces rapid mutations into a single disk write every ~500 ms.
    /// Mirrors the "debounced write" pattern the plan introduces for bucket
    /// (CustomOhhManager writes synchronously — we don't, because adds arrive
    /// every 500 ms from clipboard polling).
    private func schedulePersist() {
        persistDebounce?.cancel()
        persistDebounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            let snapshot = self.activeBucket
            self.persistInFlight = Task { [store] in
                try? await store.saveBucket(snapshot)
            }
        }
    }

    /// Cancels any pending debounced write and flushes current state to disk.
    /// Called from `applicationWillTerminate` to avoid losing a mutation that
    /// arrived within the 500 ms debounce window.
    func flushPendingWrites() async {
        persistDebounce?.cancel()
        let snapshot = activeBucket
        try? await store.saveBucket(snapshot)
        try? await store.saveSettings(settings)
    }

    /// Test alias for `flushPendingWrites()`. Kept so existing tests compile.
    func flushForTests() async {
        await flushPendingWrites()
    }
}
