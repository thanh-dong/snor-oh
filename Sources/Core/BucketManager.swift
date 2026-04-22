import Foundation
import AppKit
import UniformTypeIdentifiers
import CryptoKit

/// Core state holder for the Bucket feature.
///
/// Runs on `@MainActor` because SwiftUI observes its state. Disk I/O is
/// delegated to a `BucketStore` actor so the UI thread never blocks.
///
/// Epic 04 expands the state from a single `Bucket` to a `[Bucket]` keyed by
/// `activeBucketID`. `activeBucket` remains a computed view for call sites
/// that only care about "the currently focused bucket".
@Observable
@MainActor
final class BucketManager {

    // MARK: - Singleton

    static let shared = BucketManager()

    // MARK: - State

    private(set) var buckets: [Bucket]
    private(set) var activeBucketID: UUID
    private(set) var settings: BucketSettings = BucketSettings()

    /// All non-archived buckets (tab-strip source).
    var activeBuckets: [Bucket] { buckets.filter { !$0.archived } }

    /// All archived buckets (settings list source).
    var archivedBuckets: [Bucket] { buckets.filter { $0.archived } }

    /// Current focused bucket. Computed over `buckets[activeBucketID]` so
    /// mutations land in the right place even after the tab switches.
    var activeBucket: Bucket {
        guard let idx = buckets.firstIndex(where: { $0.id == activeBucketID }) else {
            // Self-heal: fall back to first non-archived, or create a Default.
            if let first = buckets.first(where: { !$0.archived }) {
                return first
            }
            return Bucket(name: "Default", keyboardIndex: 1)
        }
        return buckets[idx]
    }

    /// Present-only-in-tests hook to wait on the pending persist debounce.
    /// Production callers should never need this.
    var persistInFlight: Task<Void, Never>?

    // MARK: - Private

    /// Epic 07 — exposed to the view layer so quick-actions can pass the
    /// store into `ActionContext` without routing through BucketManager.
    /// Still the same instance; actor isolation keeps disk I/O safe.
    let store: BucketStore
    private var loaded = false
    private var persistDebounce: Task<Void, Never>?

    /// Latest frontmost app bundle ID, updated via `NSWorkspace` activation
    /// notifications. Used by the auto-route engine to match
    /// `RouteCondition.frontmostApp(bundleID:)` rules. Nil until the first
    /// activation notification fires.
    @MainActor private var lastFrontmostBundleID: String? = nil

    /// Observer handle for `NSWorkspace.didActivateApplicationNotification`.
    /// Retained so `deinit` can remove it and avoid a dangling observer.
    ///
    /// `@ObservationIgnored` skips the `@Observable` macro's storage rewrite
    /// so we can apply `nonisolated(unsafe)` — sound here because the handle
    /// is assigned once in `init` (on the main actor) and read once in
    /// `deinit` (nonisolated, no live concurrent references).
    @ObservationIgnored
    private nonisolated(unsafe) var frontmostObserver: NSObjectProtocol?

    /// The root of on-disk bucket storage — exposed so views can resolve
    /// sidecar thumbnails without awaiting the store actor. Captured at init.
    nonisolated let storeRootURL: URL

    /// O(1) bucket-by-id lookup — lets `routeIncomingItem` avoid an O(B) linear
    /// scan inside the per-rule loop. Rebuilt by `rebuildBucketIndex()` after
    /// any structural change to `buckets` (create / archive / restore / delete).
    /// Item-level mutations don't invalidate it.
    @ObservationIgnored
    private var bucketIndexByID: [UUID: Int] = [:]

    /// Cached id of the "default" bucket — the first non-archived bucket in
    /// tab order. Used as the no-rule-matched fallback in `routeIncomingItem`.
    /// Kept in sync with `bucketIndexByID` via `rebuildBucketIndex()`.
    @ObservationIgnored
    private var defaultBucketIDCached: UUID?

    /// Epic 02 — thresholds (in item-count) that have already fired the
    /// "I'm heavy!" speech bubble this session. In-memory only; resets each
    /// launch. Consumed by the heavy-threshold detector in `postChanged`.
    @ObservationIgnored
    private var bubbledThresholds: Set<Int> = []

    /// Epic 02 — ordered threshold list for the heavy-bucket bubble.
    static let heavyThresholds: [Int] = [20, 50, 100]

    /// Epic 07 — item IDs with a quick-action in flight. UI reads this to
    /// overlay a spinner on the source card. Written only through
    /// `markProcessing(ids:processing:)` so observers see coherent updates.
    private(set) var processingItemIDs: Set<UUID> = []

    // MARK: - Init

    /// Designated init. Production uses `.shared`; tests construct their own
    /// with an isolated temp-dir `BucketStore`.
    init(store: BucketStore = BucketStore()) {
        self.store = store
        self.storeRootURL = store.rootURL
        let seed = Bucket(name: "Default", keyboardIndex: 1)
        self.buckets = [seed]
        self.activeBucketID = seed.id
        self.bucketIndexByID = [seed.id: 0]
        self.defaultBucketIDCached = seed.id

        // Track frontmost app so auto-route `frontmostApp(bundleID:)` rules
        // can resolve without a KVO dance. Block-based observer captures
        // `self` weakly and hops to the main actor to mutate state.
        self.frontmostObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundleID = app?.bundleIdentifier
            Task { @MainActor [weak self] in
                self?.lastFrontmostBundleID = bundleID
            }
        }
    }

    deinit {
        if let obs = frontmostObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
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
            let manifest = try await store.loadManifest()
            let s = try await store.loadSettings()
            self.buckets = manifest.buckets
            self.activeBucketID = manifest.activeBucketID
            // If the active ID points at a missing/archived bucket, fall back.
            if !self.buckets.contains(where: { $0.id == self.activeBucketID && !$0.archived }) {
                if let first = self.buckets.first(where: { !$0.archived }) {
                    self.activeBucketID = first.id
                }
            }
            self.settings = s
            rebuildBucketIndex()
        } catch {
            NSLog("[bucket] load failed: \(error)")
        }
        seedDefaultIgnoredBundleIDsIfNeeded()
    }

    /// One-time migration: seed the ignore list with common terminals and
    /// password managers so text selection in Terminal / credentials
    /// copied from 1Password don't get captured out of the box. Guarded by
    /// `DefaultsKey.bucketIgnoreDefaultsSeeded` so existing users who have
    /// curated their own list aren't force-updated.
    private func seedDefaultIgnoredBundleIDsIfNeeded() {
        let key = DefaultsKey.bucketIgnoreDefaultsSeeded
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)

        var s = settings
        s.ignoredBundleIDs.formUnion(BucketDefaults.ignoredBundleIDs)
        updateSettings(s)
    }

    // MARK: - Active tab

    func setActiveBucket(id: UUID) {
        guard let bucket = buckets.first(where: { $0.id == id }), !bucket.archived else { return }
        guard activeBucketID != id else { return }
        activeBucketID = id
        schedulePersist()
        postChanged(change: .activeBucketChanged, source: .panel, itemID: nil, bucketID: id)
    }

    // MARK: - Bucket CRUD

    @discardableResult
    func createBucket(
        name: String,
        colorHex: String? = nil,
        emoji: String? = nil
    ) -> UUID {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "Untitled" : trimmed
        let resolvedName = uniqueBucketName(from: base)
        let resolvedColor = colorHex ?? nextPaletteColor()
        let bucket = Bucket(
            name: resolvedName,
            colorHex: resolvedColor,
            emoji: emoji,
            archived: false,
            keyboardIndex: nextFreeKeyboardIndex()
        )
        buckets.append(bucket)
        if buckets.filter({ !$0.archived }).count > 12 {
            NSLog("[bucket] soft warning: active bucket count exceeds 12 (now \(buckets.filter { !$0.archived }.count))")
        }
        rebuildBucketIndex()
        schedulePersist()
        postChanged(change: .bucketCreated, source: .panel, itemID: nil, bucketID: bucket.id)
        return bucket.id
    }

    func renameBucket(id: UUID, to newName: String) {
        guard let idx = buckets.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        buckets[idx].name = trimmed
        schedulePersist()
        postChanged(change: .bucketUpdated, source: .panel, itemID: nil, bucketID: id)
    }

    func setColor(id: UUID, colorHex: String) {
        guard let idx = buckets.firstIndex(where: { $0.id == id }) else { return }
        buckets[idx].colorHex = colorHex
        schedulePersist()
        postChanged(change: .bucketUpdated, source: .panel, itemID: nil, bucketID: id)
    }

    func setEmoji(id: UUID, emoji: String?) {
        guard let idx = buckets.firstIndex(where: { $0.id == id }) else { return }
        // Normalize empty string to nil so UI consistently treats "no emoji".
        let normalized = emoji?.trimmingCharacters(in: .whitespacesAndNewlines)
        buckets[idx].emoji = (normalized?.isEmpty ?? true) ? nil : normalized
        schedulePersist()
        postChanged(change: .bucketUpdated, source: .panel, itemID: nil, bucketID: id)
    }

    /// Archives a bucket. Refuses if the target is the active bucket OR if it
    /// would leave zero active buckets. Callers must `setActiveBucket(id:)` to
    /// something else first — this is intentional so focus never shifts silently.
    func archiveBucket(id: UUID) {
        guard let idx = buckets.firstIndex(where: { $0.id == id }) else { return }
        guard !buckets[idx].archived else { return }
        if id == activeBucketID {
            NSLog("[bucket] archiveBucket: refusing to archive active bucket \(id); call setActiveBucket first")
            return
        }
        if buckets.filter({ !$0.archived }).count <= 1 {
            NSLog("[bucket] archiveBucket: refusing — would leave zero active buckets")
            return
        }
        buckets[idx].archived = true
        buckets[idx].keyboardIndex = nil
        rebuildBucketIndex()
        schedulePersist()
        postChanged(change: .bucketArchived, source: .panel, itemID: nil, bucketID: id)
    }

    func restoreBucket(id: UUID) {
        guard let idx = buckets.firstIndex(where: { $0.id == id }) else { return }
        guard buckets[idx].archived else { return }
        buckets[idx].archived = false
        buckets[idx].keyboardIndex = nextFreeKeyboardIndex()
        rebuildBucketIndex()
        schedulePersist()
        postChanged(change: .bucketRestored, source: .panel, itemID: nil, bucketID: id)
    }

    /// Permanently deletes `id`.
    ///
    /// - If `mergeInto` is nil: requires the target to not be the active bucket
    ///   (caller must pre-switch). The bucket's on-disk `<id>/` subdirectory
    ///   is removed recursively; auto-route rules pointing at it are dropped.
    /// - If `mergeInto` is non-nil: items are prepended to the destination,
    ///   sidecar files move from `<src>/` to `<dst>/` with paths rewritten,
    ///   auto-route rules are re-pointed at the destination. The `mergeInto`
    ///   target must be an existing, non-archived bucket.
    func deleteBucket(id: UUID, mergeInto: UUID? = nil) {
        guard let idx = buckets.firstIndex(where: { $0.id == id }) else { return }
        if let destID = mergeInto {
            guard let destIdx = buckets.firstIndex(where: { $0.id == destID }),
                  !buckets[destIdx].archived else {
                NSLog("[bucket] deleteBucket: mergeInto target missing or archived; aborting")
                return
            }
            performMergeDelete(srcIdx: idx, destIdx: destIdx)
        } else {
            if id == activeBucketID {
                NSLog("[bucket] deleteBucket: refusing — active bucket must be switched before non-merge delete")
                return
            }
            performHardDelete(at: idx)
        }
    }

    private func performHardDelete(at idx: Int) {
        let removed = buckets.remove(at: idx)
        settings.autoRouteRules.removeAll { $0.bucketID == removed.id }
        rebuildBucketIndex()
        Task { [store, bucketID = removed.id] in
            await store.deleteBucketDirectory(bucketID: bucketID)
        }
        schedulePersist()
        postChanged(change: .bucketDeleted, source: .panel, itemID: nil, bucketID: removed.id)
    }

    private func performMergeDelete(srcIdx: Int, destIdx: Int) {
        // Snapshot both ids before any mutation.
        let srcID = buckets[srcIdx].id
        let destID = buckets[destIdx].id

        // Rewrite item paths: src's items' `<src-id>/...` prefixes become `<dest-id>/...`.
        let rewrittenItems = buckets[srcIdx].items.map { rewriteItemPaths($0, from: srcID, to: destID) }
        buckets[destIdx].items.insert(contentsOf: rewrittenItems, at: 0)

        // Re-point auto-route rules.
        for i in settings.autoRouteRules.indices
        where settings.autoRouteRules[i].bucketID == srcID {
            settings.autoRouteRules[i].bucketID = destID
        }

        // Fold the on-disk sidecar tree.
        Task { [store] in
            try? await store.mergeBucketDirectory(from: srcID, into: destID)
        }

        // Remove src from state.
        buckets.remove(at: srcIdx)
        rebuildBucketIndex()

        if activeBucketID == srcID {
            activeBucketID = destID
            postChanged(change: .activeBucketChanged, source: .panel, itemID: nil, bucketID: destID)
        }
        schedulePersist()
        postChanged(change: .bucketDeleted, source: .panel, itemID: nil, bucketID: srcID)
    }

    /// Moves an item from its current bucket to `toBucket`. Rewrites the
    /// sidecar file path from `<src>/...` to `<dst>/...` and moves the file
    /// on disk. No-op if either end is missing, or if the item already lives
    /// in the destination.
    func moveItem(_ itemID: UUID, toBucket destID: UUID) {
        guard let destIdx = buckets.firstIndex(where: { $0.id == destID }) else { return }
        for srcIdx in buckets.indices {
            guard srcIdx != destIdx else { continue }
            if let itemIdx = buckets[srcIdx].items.firstIndex(where: { $0.id == itemID }) {
                let srcID = buckets[srcIdx].id
                var item = buckets[srcIdx].items.remove(at: itemIdx)
                item.lastAccessedAt = Date()
                let rewritten = rewriteItemPaths(item, from: srcID, to: destID)
                buckets[destIdx].items.insert(rewritten, at: 0)

                // Move sidecar files on disk so paths match.
                let toMove = collectRelativePaths(of: item).filter {
                    $0.hasPrefix("\(srcID.uuidString)/")
                }
                if !toMove.isEmpty {
                    Task { [store] in
                        for rel in toMove {
                            _ = try? await store.moveSidecarBetweenBuckets(
                                relativePath: rel,
                                from: srcID,
                                to: destID
                            )
                        }
                    }
                }

                schedulePersist()
                postChanged(change: .removed, source: .panel, itemID: itemID, bucketID: srcID)
                postChanged(change: .added, source: .panel, itemID: itemID, bucketID: destID)
                return
            }
        }
    }

    /// Rewrites any sidecar relative paths on an item from the `<src>/` prefix
    /// to a `<dst>/` prefix. Used by `moveItem` and `deleteBucket(mergeInto:)`.
    private func rewriteItemPaths(_ item: BucketItem, from src: UUID, to dst: UUID) -> BucketItem {
        let srcPrefix = "\(src.uuidString)/"
        let dstPrefix = "\(dst.uuidString)/"
        var updated = item
        if var fileRef = updated.fileRef, let cached = fileRef.cachedPath, cached.hasPrefix(srcPrefix) {
            fileRef.cachedPath = dstPrefix + cached.dropFirst(srcPrefix.count)
            updated.fileRef = fileRef
        }
        if var urlMeta = updated.urlMeta {
            if let fav = urlMeta.faviconPath, fav.hasPrefix(srcPrefix) {
                urlMeta.faviconPath = dstPrefix + fav.dropFirst(srcPrefix.count)
            }
            if let og = urlMeta.ogImagePath, og.hasPrefix(srcPrefix) {
                urlMeta.ogImagePath = dstPrefix + og.dropFirst(srcPrefix.count)
            }
            updated.urlMeta = urlMeta
        }
        return updated
    }

    private func collectRelativePaths(of item: BucketItem) -> [String] {
        var out: [String] = []
        if let p = item.fileRef?.cachedPath { out.append(p) }
        if let p = item.urlMeta?.faviconPath { out.append(p) }
        if let p = item.urlMeta?.ogImagePath { out.append(p) }
        return out
    }

    // MARK: - Item mutations

    /// Inserts an item at the head (newest-first) of the auto-routed bucket,
    /// fires `.bucketChanged`, enforces per-bucket LRU caps, schedules a persist.
    ///
    /// **Dedupe semantics**: if an equivalent item already exists anywhere in
    /// the destination bucket, the existing item is *promoted* to the top with
    /// a refreshed `lastAccessedAt` — no duplicate is added.
    func add(_ item: BucketItem, source: BucketChangeSource) {
        let destID = routeIncomingItem(
            kind: item.kind,
            sourceBundleID: item.sourceBundleID,
            urlHost: item.urlMeta.flatMap { URL(string: $0.urlString)?.host }
        )
        insertItem(item, intoBucketID: destID, source: source)
    }

    /// Bypass auto-routing — used by drag-to-tab and callers who already know
    /// the destination (e.g. moveItem, tests).
    func add(_ item: BucketItem, source: BucketChangeSource, toBucket bucketID: UUID) {
        insertItem(item, intoBucketID: bucketID, source: source)
    }

    /// Core insert path — does dedupe, eviction, notification, persist. All
    /// other add entrypoints funnel through here.
    private func insertItem(_ item: BucketItem, intoBucketID bucketID: UUID, source: BucketChangeSource) {
        guard let idx = buckets.firstIndex(where: { $0.id == bucketID }) else { return }
        if let existingIdx = duplicateIndex(of: item, inBucketAt: idx) {
            promoteExisting(bucketIdx: idx, itemIdx: existingIdx, source: source)
            return
        }
        buckets[idx].items.insert(item, at: 0)
        evictIfNeeded(bucketIdx: idx)
        postChanged(change: .added, source: source, itemID: item.id, bucketID: buckets[idx].id)
        schedulePersist()

        // Epic 07 — eager-mode OCR: kick off indexing for every new image as
        // it lands. No-op in lazy/manual modes. Derived images (resize etc.)
        // already have pixel text in `ocrText` only if the source did, so we
        // re-index them explicitly — small cost, keeps search coverage sane.
        if item.kind == .image, settings.ocrIndexingMode == .eager {
            let root = storeRootURL
            Task.detached(priority: .utility) {
                await OCRIndex.shared.ensureIndexed(items: [item], storeRootURL: root)
            }
        }
    }

    /// Entry point for the auto-route engine. Returns the bucketID the item
    /// should land in based on configured rules; falls back to the **default**
    /// bucket (first non-archived in tab order) when no rule matches or the
    /// matched rule's target is archived / missing.
    ///
    /// Performance: bucket target resolution is O(1) via `bucketIndexByID`,
    /// so total cost is O(R) in the number of enabled rules. Condition
    /// evaluation is already O(1). Iteration order is `settings.autoRouteRules`
    /// — first enabled match wins. Disabled rules are skipped silently.
    func routeIncomingItem(
        kind: BucketItemKind,
        sourceBundleID: String? = nil,
        urlHost: String? = nil
    ) -> UUID {
        for rule in settings.autoRouteRules where rule.enabled {
            guard BucketManager.evaluateCondition(
                rule.condition,
                itemKind: kind,
                sourceBundleID: sourceBundleID,
                urlHost: urlHost,
                frontmostBundleID: lastFrontmostBundleID
            ) else { continue }

            if let idx = bucketIndexByID[rule.bucketID], !buckets[idx].archived {
                return buckets[idx].id
            }
            // Target missing or archived — skip to next rule.
        }
        // No rule matched: land in the default bucket, not the active one.
        // Cache is maintained by `rebuildBucketIndex`; `activeBucketID` is a
        // last-resort safety net (archive/delete invariants keep ≥1 non-archived).
        return defaultBucketIDCached ?? activeBucketID
    }

    /// Rebuilds `bucketIndexByID` and `defaultBucketIDCached`. Called only on
    /// structural changes to `buckets` (create / archive / restore / delete).
    /// Item-level mutations don't invalidate these caches.
    private func rebuildBucketIndex() {
        var map: [UUID: Int] = [:]
        map.reserveCapacity(buckets.count)
        for (i, b) in buckets.enumerated() {
            map[b.id] = i
        }
        bucketIndexByID = map
        defaultBucketIDCached = buckets.first(where: { !$0.archived })?.id
    }

    /// Pure condition matcher — no side effects, no state. Factored out as a
    /// `static` method so tests can drive it without constructing a manager.
    static func evaluateCondition(
        _ condition: RouteCondition,
        itemKind: BucketItemKind,
        sourceBundleID: String?,
        urlHost: String?,
        frontmostBundleID: String?
    ) -> Bool {
        switch condition {
        case .frontmostApp(let id):
            return frontmostBundleID == id
        case .itemKind(let k):
            return itemKind == k
        case .sourceApp(let id):
            return sourceBundleID == id
        case .urlHost(let host):
            return (urlHost ?? "").caseInsensitiveCompare(host) == .orderedSame
        }
    }

    // MARK: - Auto-route rule mutations

    /// Appends a new rule. Persisted via `updateSettings`.
    func addAutoRouteRule(_ rule: AutoRouteRule) {
        var s = settings
        s.autoRouteRules.append(rule)
        updateSettings(s)
    }

    /// Replaces an existing rule matched by `id`. No-op if the id is unknown.
    func updateAutoRouteRule(_ rule: AutoRouteRule) {
        var s = settings
        guard let idx = s.autoRouteRules.firstIndex(where: { $0.id == rule.id }) else { return }
        s.autoRouteRules[idx] = rule
        updateSettings(s)
    }

    func removeAutoRouteRule(id: UUID) {
        var s = settings
        s.autoRouteRules.removeAll { $0.id == id }
        updateSettings(s)
    }

    /// Flips `enabled` on the rule with this id. No-op if unknown.
    func toggleAutoRouteRule(id: UUID) {
        var s = settings
        guard let idx = s.autoRouteRules.firstIndex(where: { $0.id == id }) else { return }
        s.autoRouteRules[idx].enabled.toggle()
        updateSettings(s)
    }

    /// Moves the rule at `fromIndex` to `toIndex` (clamped). Used by the
    /// settings list to let users re-prioritize auto-route rules.
    func moveAutoRouteRule(fromIndex: Int, toIndex: Int) {
        var s = settings
        guard s.autoRouteRules.indices.contains(fromIndex) else { return }
        let clampedTo = max(0, min(toIndex, s.autoRouteRules.count - 1))
        guard fromIndex != clampedTo else { return }
        let rule = s.autoRouteRules.remove(at: fromIndex)
        s.autoRouteRules.insert(rule, at: clampedTo)
        updateSettings(s)
    }

    #if DEBUG
    /// Test-only injection for frontmost bundle ID. Production callers
    /// rely on the `NSWorkspace` activation observer to populate this.
    @MainActor
    func _setLastFrontmostBundleID(_ id: String?) {
        lastFrontmostBundleID = id
    }
    #endif

    /// Moves the item at `itemIdx` in `bucketIdx` to the head of that bucket
    /// and refreshes `lastAccessedAt`. Used for dedupe hits.
    private func promoteExisting(bucketIdx: Int, itemIdx: Int, source: BucketChangeSource) {
        var existing = buckets[bucketIdx].items.remove(at: itemIdx)
        existing.lastAccessedAt = Date()
        buckets[bucketIdx].items.insert(existing, at: 0)
        postChanged(change: .added, source: source, itemID: existing.id, bucketID: buckets[bucketIdx].id)
        schedulePersist()
    }

    /// Async entry point for file drops. Copies the source into the sidecar
    /// directory **before** inserting, so the item's `cachedPath` is populated
    /// and the bucket survives restart.
    ///
    /// Dedupes by `originalPath` *before* the sidecar copy — so re-dragging
    /// the same file is a cheap no-op (no redundant disk I/O).
    func add(fileAt url: URL, source: BucketChangeSource, stackGroupID: UUID? = nil) async {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        let kind = classifyFile(url: url, isDirectory: isDir.boolValue)

        let destID = routeIncomingItem(kind: kind)

        // Cheap path-based dedupe within destination — no sidecar copy on a hit.
        if let destIdx = buckets.firstIndex(where: { $0.id == destID }),
           let idx = buckets[destIdx].items.firstIndex(where: { existing in
                guard existing.kind == .file || existing.kind == .folder || existing.kind == .image,
                      let p = existing.fileRef?.originalPath, !p.isEmpty else { return false }
                return p == url.path
           }) {
            promoteExisting(bucketIdx: destIdx, itemIdx: idx, source: source)
            return
        }

        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        let uti = (try? url.resourceValues(forKeys: [.typeIdentifierKey]).typeIdentifier)
            ?? (isDir.boolValue ? "public.folder" : "public.data")

        let itemID = UUID()
        var cachedPath: String? = nil
        if !isDir.boolValue {
            let subdir = kind == .image ? "images" : "files"
            cachedPath = try? await store.copySidecar(
                from: url,
                bucketID: destID,
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
        insertItem(item, intoBucketID: destID, source: source)
    }

    /// Async entry point for raw image bytes (pasteboard image drops).
    /// Writes the PNG bytes into the sidecar and inserts with `cachedPath` set.
    ///
    /// Dedupes by SHA-256 content hash *before* the sidecar write — so
    /// re-copying the same image is a cheap no-op that just re-surfaces the
    /// existing item.
    func add(imageData data: Data, source: BucketChangeSource, stackGroupID: UUID? = nil) async {
        let hash = sha256Hex(data)
        let destID = routeIncomingItem(kind: .image)

        if let destIdx = buckets.firstIndex(where: { $0.id == destID }),
           let idx = buckets[destIdx].items.firstIndex(where: { $0.contentHash == hash }) {
            promoteExisting(bucketIdx: destIdx, itemIdx: idx, source: source)
            return
        }

        let itemID = UUID()
        let cachedPath = try? await store.writeSidecar(
            data,
            bucketID: destID,
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
        insertItem(item, intoBucketID: destID, source: source)
    }

    private func classifyFile(url: URL, isDirectory: Bool) -> BucketItemKind {
        if isDirectory { return .folder }
        if let uti = (try? url.resourceValues(forKeys: [.typeIdentifierKey]).typeIdentifier),
           let t = UTType(uti), t.conforms(to: .image) {
            return .image
        }
        return .file
    }

    /// Removes by ID; deletes any sidecar files. Scans all buckets so a stale
    /// UUID from any tab still lands on the right bucket.
    func remove(id: UUID, source: BucketChangeSource = .panel) {
        for bucketIdx in buckets.indices {
            if let itemIdx = buckets[bucketIdx].items.firstIndex(where: { $0.id == id }) {
                let removed = buckets[bucketIdx].items.remove(at: itemIdx)
                cleanupSidecars(for: [removed])
                postChanged(change: .removed, source: source, itemID: id, bucketID: buckets[bucketIdx].id)
                schedulePersist()
                return
            }
        }
    }

    /// Toggles `pinned`; pinned items are never auto-evicted and never
    /// removed by `clearUnpinned()`.
    func togglePin(id: UUID, source: BucketChangeSource = .panel) {
        for bucketIdx in buckets.indices {
            if let itemIdx = buckets[bucketIdx].items.firstIndex(where: { $0.id == id }) {
                buckets[bucketIdx].items[itemIdx].pinned.toggle()
                let kind: BucketChangeKind = buckets[bucketIdx].items[itemIdx].pinned ? .pinned : .unpinned
                postChanged(change: kind, source: source, itemID: id, bucketID: buckets[bucketIdx].id)
                schedulePersist()
                return
            }
        }
    }

    // MARK: - Epic 07 — Quick-action hooks

    /// Writes OCR output back to an existing image item. Called by
    /// `ExtractTextAction` (manual) and `OCRIndex` (lazy / eager). A nil
    /// `text` is treated as "ran OCR but found nothing textual" — we still
    /// stamp `ocrIndexedAt` so the index knows not to retry.
    func updateOCR(itemID: UUID, text: String?, locale: String?) {
        for bucketIdx in buckets.indices {
            if let itemIdx = buckets[bucketIdx].items.firstIndex(where: { $0.id == itemID }) {
                buckets[bucketIdx].items[itemIdx].ocrText = text
                buckets[bucketIdx].items[itemIdx].ocrLocale = locale
                buckets[bucketIdx].items[itemIdx].ocrIndexedAt = Date()
                schedulePersist()
                return
            }
        }
    }

    /// Inserts a derived item immediately after its source (not at the head),
    /// so resize / convert / translate results appear next to the original
    /// rather than teleporting to the top of a long bucket. Falls back to
    /// head-insert if the source has been removed in the meantime.
    func insertDerivedItem(
        _ item: BucketItem,
        afterSourceID sourceID: UUID,
        bucketID: UUID,
        source: BucketChangeSource = .panel
    ) {
        guard let bucketIdx = buckets.firstIndex(where: { $0.id == bucketID }) else { return }
        var derived = item
        derived.derivedFromItemID = sourceID
        if let srcIdx = buckets[bucketIdx].items.firstIndex(where: { $0.id == sourceID }) {
            buckets[bucketIdx].items.insert(derived, at: srcIdx + 1)
        } else {
            buckets[bucketIdx].items.insert(derived, at: 0)
        }
        evictIfNeeded(bucketIdx: bucketIdx)
        postChanged(change: .added, source: source, itemID: derived.id, bucketID: buckets[bucketIdx].id)
        schedulePersist()
    }

    /// Test/debug helper: which bucket currently holds this item?
    func bucketID(forItemID id: UUID) -> UUID? {
        for b in buckets where b.items.contains(where: { $0.id == id }) {
            return b.id
        }
        return nil
    }

    /// Look up an item by ID across every bucket. Used by `BucketCardView` to
    /// resolve a derived item's source (for thumbnail + "from X" label).
    /// Returns nil if the source has been removed since the derivation.
    func findItem(id: UUID) -> BucketItem? {
        for b in buckets {
            if let item = b.items.first(where: { $0.id == id }) {
                return item
            }
        }
        return nil
    }

    /// Returns the current image items without an OCR stamp — consumed by
    /// `OCRIndex.ensureIndexed`. Static-free so tests can drive it.
    func unindexedImageItems() -> [BucketItem] {
        activeBucket.items.filter { $0.kind == .image && $0.ocrIndexedAt == nil }
    }

    /// Flip the processing flag for a set of items. Called by
    /// `BucketActionRunner` on both enter and exit so the UI spinner appears
    /// and vanishes in lockstep.
    func markProcessing(ids: [UUID], processing: Bool) {
        if processing {
            processingItemIDs.formUnion(ids)
        } else {
            processingItemIDs.subtract(ids)
        }
    }

    /// Removes all unpinned items and their sidecars from the active bucket.
    func clearUnpinned(source: BucketChangeSource = .panel) {
        guard let idx = buckets.firstIndex(where: { $0.id == activeBucketID }) else { return }
        let removed = buckets[idx].items.filter { !$0.pinned }
        guard !removed.isEmpty else { return }
        buckets[idx].items.removeAll { !$0.pinned }
        cleanupSidecars(for: removed)
        postChanged(change: .cleared, source: source, itemID: nil, bucketID: buckets[idx].id)
        schedulePersist()
    }

    /// Fuzzy-ish filter across text, URL string, URL title, file display name,
    /// `sourceBundleID`, and — for `.image` items — OCR'd text when available
    /// (Epic 07). Case-insensitive, no ranking. Scoped to active bucket to
    /// match the visible list.
    ///
    /// Note: this is the *pure* matcher. It does **not** trigger OCR; the UI
    /// layer calls `OCRIndex.ensureIndexed(items:)` before invoking `search`
    /// when `settings.ocrIndexingMode == .lazy`. This keeps the matcher
    /// synchronous and testable without a Vision dependency.
    func search(_ query: String) -> [BucketItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = activeBucket.items
        guard !q.isEmpty else { return source }
        let needle = q.lowercased()
        return source.filter { item in
            if item.text?.lowercased().contains(needle) == true { return true }
            if item.urlMeta?.urlString.lowercased().contains(needle) == true { return true }
            if item.urlMeta?.title?.lowercased().contains(needle) == true { return true }
            if item.fileRef?.displayName.lowercased().contains(needle) == true { return true }
            if item.sourceBundleID?.lowercased().contains(needle) == true { return true }
            // Epic 07: image items are findable by their OCR'd text.
            if item.kind == .image,
               item.ocrText?.lowercased().contains(needle) == true { return true }
            return false
        }
    }

    // MARK: - Settings

    func updateSettings(_ new: BucketSettings) {
        self.settings = new
        for idx in buckets.indices {
            evictIfNeeded(bucketIdx: idx)
        }
        Task { [store] in
            try? await store.saveSettings(new)
        }
    }

    // MARK: - Dedupe helper

    /// Returns the index of an existing item in bucket at `bucketIdx` that is
    /// "the same" as `candidate`, or nil if there's no match.
    ///
    /// Match rules (kinds must agree):
    ///   - `.text` / `.richText`: payloads equal.
    ///   - `.url`: URL strings equal.
    ///   - `.color`: hex strings equal.
    ///   - `.file` / `.folder`: either same `originalPath` or same
    ///     `contentHash` (if both sides computed one).
    ///   - `.image`: same `contentHash`.
    private func duplicateIndex(of candidate: BucketItem, inBucketAt bucketIdx: Int) -> Int? {
        buckets[bucketIdx].items.firstIndex { existing in
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

    // MARK: - LRU eviction (per bucket)

    private func evictIfNeeded(bucketIdx: Int) {
        guard buckets.indices.contains(bucketIdx) else { return }
        if buckets[bucketIdx].items.count > settings.maxItems {
            evictOldestUnpinned(bucketIdx: bucketIdx, toCount: settings.maxItems)
        }
        let approxSize = buckets[bucketIdx].items.reduce(Int64(0)) { acc, item in
            acc + (item.fileRef?.byteSize ?? 0)
        }
        if approxSize > settings.maxStorageBytes {
            evictOldestUnpinnedBySize(bucketIdx: bucketIdx, target: settings.maxStorageBytes)
        }
    }

    private func evictOldestUnpinned(bucketIdx: Int, toCount maxCount: Int) {
        var removed: [BucketItem] = []
        while buckets[bucketIdx].items.count > maxCount {
            guard let lastUnpinnedIdx = buckets[bucketIdx].items.lastIndex(where: { !$0.pinned }) else {
                break
            }
            removed.append(buckets[bucketIdx].items.remove(at: lastUnpinnedIdx))
        }
        if !removed.isEmpty {
            cleanupSidecars(for: removed)
        }
    }

    private func evictOldestUnpinnedBySize(bucketIdx: Int, target: Int64) {
        var removed: [BucketItem] = []
        var size = buckets[bucketIdx].items.reduce(Int64(0)) { $0 + ($1.fileRef?.byteSize ?? 0) }
        while size > target {
            guard let idx = buckets[bucketIdx].items.lastIndex(where: { !$0.pinned }) else { break }
            let item = buckets[bucketIdx].items.remove(at: idx)
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

    // MARK: - Palette / keyboard helpers

    private func nextPaletteColor() -> String {
        let used = Set(buckets.map { $0.colorHex })
        if let free = BucketPalette.swatches.first(where: { !used.contains($0) }) {
            return free
        }
        return BucketPalette.swatches[buckets.count % BucketPalette.swatches.count]
    }

    /// Returns `base` if no existing bucket already holds that name; otherwise
    /// suffixes " 2", " 3", … until a free slot is found. Matching is exact
    /// and whitespace-trimmed, scoped across active + archived buckets to
    /// avoid restore-time collisions.
    func uniqueBucketName(from base: String) -> String {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.isEmpty ? "Untitled" : trimmed
        let taken = Set(buckets.map { $0.name })
        if !taken.contains(candidate) { return candidate }
        var n = 2
        while taken.contains("\(candidate) \(n)") {
            n += 1
        }
        return "\(candidate) \(n)"
    }

    private func nextFreeKeyboardIndex() -> Int? {
        let used = Set(buckets.compactMap { $0.keyboardIndex })
        for candidate in 1...9 where !used.contains(candidate) {
            return candidate
        }
        return nil
    }

    // MARK: - Notifications

    private func postChanged(
        change: BucketChangeKind,
        source: BucketChangeSource,
        itemID: UUID?,
        bucketID: UUID? = nil
    ) {
        var info: [String: Any] = [
            "change": change.rawValue,
            "source": source.rawValue,
        ]
        if let itemID {
            info["itemID"] = itemID
        }
        if let bucketID {
            info["bucketID"] = bucketID
        }
        NotificationCenter.default.post(
            name: .bucketChanged,
            object: nil,
            userInfo: info
        )

        // Epic 02: heavy threshold detection — fires *after* the change
        // notification so observers see the fresh count first.
        maybePostHeavyThreshold(change: change)
    }

    /// Posts `.bucketHeavy` once per session per threshold when the active
    /// bucket's item count crosses 20/50/100. `.cleared` and `.removed` reset
    /// the already-fired set for any threshold the bucket dropped below, so a
    /// user who clears and refills their bucket gets re-nudged.
    private func maybePostHeavyThreshold(change: BucketChangeKind) {
        let count = totalActiveItemCount()
        // Reset any thresholds we've dropped below — lets a cleared bucket
        // warn again when it refills.
        for t in Self.heavyThresholds where count < t {
            bubbledThresholds.remove(t)
        }
        guard change == .added else { return }
        guard let crossed = Self.crossedThreshold(count: count, fired: bubbledThresholds) else {
            return
        }
        bubbledThresholds.insert(crossed)
        NotificationCenter.default.post(
            name: .bucketHeavy,
            object: nil,
            userInfo: ["threshold": crossed, "count": count]
        )
    }

    /// Sum of item counts across all non-archived buckets — the "everything
    /// snor-oh is carrying" number that the badge and heavy bubble quote.
    func totalActiveItemCount() -> Int {
        buckets.reduce(0) { acc, b in acc + (b.archived ? 0 : b.items.count) }
    }

    /// Pure helper — exposed for tests. Returns the highest threshold `count`
    /// has just reached that hasn't already fired.
    static func crossedThreshold(count: Int, fired: Set<Int>) -> Int? {
        heavyThresholds
            .filter { count >= $0 && !fired.contains($0) }
            .max()
    }

    /// Epic 02 — formats the badge label. Returns `nil` when the bucket is
    /// empty (badge hidden). Counts over 99 show as "99+".
    static func badgeText(count: Int) -> String? {
        guard count > 0 else { return nil }
        return count > 99 ? "99+" : String(count)
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
            let snapshot = BucketManifestV2(
                schemaVersion: BucketStore.currentSchemaVersion,
                activeBucketID: self.activeBucketID,
                buckets: self.buckets
            )
            self.persistInFlight = Task { [store] in
                try? await store.saveManifest(snapshot)
            }
        }
    }

    /// Cancels any pending debounced write and flushes current state to disk.
    /// Called from `applicationWillTerminate` to avoid losing a mutation that
    /// arrived within the 500 ms debounce window.
    func flushPendingWrites() async {
        persistDebounce?.cancel()
        let snapshot = BucketManifestV2(
            schemaVersion: BucketStore.currentSchemaVersion,
            activeBucketID: activeBucketID,
            buckets: buckets
        )
        try? await store.saveManifest(snapshot)
        try? await store.saveSettings(settings)
    }

    /// Test alias for `flushPendingWrites()`. Kept so existing tests compile.
    func flushForTests() async {
        await flushPendingWrites()
    }

    // MARK: - Bucket switcher (Phase 6)

    /// Pure resolver for the ⌃⌥N bucket-switcher hotkey. Given a 1-based index
    /// `n` and the current list of visible (non-archived) buckets, returns the
    /// target bucket's UUID, or nil when `n` is out of range. Factored as a
    /// `static` helper so tests don't need the Carbon event plumbing.
    static func resolveBucketSwitcherTarget(n: Int, activeBuckets: [Bucket]) -> UUID? {
        guard n >= 1, n <= activeBuckets.count else { return nil }
        return activeBuckets[n - 1].id
    }
}
