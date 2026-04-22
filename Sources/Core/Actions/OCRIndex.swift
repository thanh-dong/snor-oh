import Foundation

/// Epic 07 — batched OCR index for `.image` items.
///
/// **Modes** (see `BucketSettings.ocrIndexingMode`):
///   - `.eager` — caller invokes `ensureIndexed` on every image add.
///   - `.lazy`  — caller invokes `ensureIndexed` on the first search per
///     session (or on each search when there are still un-indexed images).
///   - `.manual` — `ensureIndexed` is never called automatically; only
///     explicit `ExtractTextAction` runs touch the index.
///
/// Implemented as an actor so concurrent callers queue rather than collide
/// on Vision. In-flight item IDs are tracked to drop duplicate requests
/// (e.g. search typed quickly → three ensureIndexed calls hitting the same
/// item).
actor OCRIndex {

    static let shared = OCRIndex()

    /// IDs currently being OCR'd. Used to dedupe concurrent ensureIndexed
    /// calls — the second caller waits on the first rather than running
    /// Vision again.
    private var inFlight: Set<UUID> = []

    /// Broadcast observer: fired whenever a batch of OCR writebacks lands
    /// so the UI can refresh its search-result view. Consumers register
    /// themselves via the standard `NotificationCenter` — see
    /// `Notification.Name.bucketOCRIndexed`.
    private func postChanged(itemIDs: [UUID]) async {
        guard !itemIDs.isEmpty else { return }
        await MainActor.run {
            NotificationCenter.default.post(
                name: .bucketOCRIndexed,
                object: nil,
                userInfo: ["itemIDs": itemIDs]
            )
        }
    }

    /// OCRs every image in `items` whose `ocrIndexedAt` is nil. Skips items
    /// already in-flight from another call. Bounded-parallelism (4 tasks at
    /// a time) to keep the Neural Engine responsive.
    func ensureIndexed(items: [BucketItem], storeRootURL: URL) async {
        let pending = items.filter {
            $0.kind == .image && $0.ocrIndexedAt == nil && !inFlight.contains($0.id)
        }
        guard !pending.isEmpty else { return }
        for item in pending { inFlight.insert(item.id) }

        var written: [UUID] = []
        // Bounded TaskGroup: at most 4 concurrent OCR runs. Empirically,
        // more doesn't help on M-series because Vision already parallelizes
        // internally.
        await withTaskGroup(of: (UUID, ExtractTextAction.OCRResult?).self) { group in
            var launched = 0
            var iterator = pending.makeIterator()
            let limit = 4
            while launched < limit, let next = iterator.next() {
                addOCRTask(group: &group, item: next, storeRootURL: storeRootURL)
                launched += 1
            }
            while let (id, result) = await group.next() {
                if let result {
                    await MainActor.run {
                        BucketManager.shared.updateOCR(
                            itemID: id,
                            text: result.text,
                            locale: result.locale
                        )
                    }
                    written.append(id)
                }
                // Stamp-failed items too, so we don't re-try forever.
                if result == nil {
                    await MainActor.run {
                        BucketManager.shared.updateOCR(
                            itemID: id,
                            text: nil,
                            locale: nil
                        )
                    }
                }
                if let next = iterator.next() {
                    addOCRTask(group: &group, item: next, storeRootURL: storeRootURL)
                }
            }
        }
        for item in pending { inFlight.remove(item.id) }
        await postChanged(itemIDs: written)
    }

    /// Returns true if any image in the active bucket still needs indexing.
    /// UI layer uses this to decide whether to show the "indexing…" spinner
    /// when the user starts typing in the search box.
    func hasPendingIndex(items: [BucketItem]) -> Bool {
        items.contains {
            $0.kind == .image && $0.ocrIndexedAt == nil && !inFlight.contains($0.id)
        }
    }

    private func addOCRTask(
        group: inout TaskGroup<(UUID, ExtractTextAction.OCRResult?)>,
        item: BucketItem,
        storeRootURL: URL
    ) {
        let id = item.id
        let rel = item.fileRef?.cachedPath
        group.addTask {
            guard let rel else { return (id, nil) }
            let url = storeRootURL.appendingPathComponent(rel)
            do {
                let result = try await ExtractTextAction.runOCR(imageAt: url)
                return (id, result)
            } catch {
                return (id, nil)
            }
        }
    }
}

extension Notification.Name {
    /// Posted when a batch of `OCRIndex.ensureIndexed` writebacks has landed.
    /// `userInfo["itemIDs"]` is `[UUID]`. Search UI listens and re-runs the
    /// current query.
    static let bucketOCRIndexed = Notification.Name("bucketOCRIndexed")
}
