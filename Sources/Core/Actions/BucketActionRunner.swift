import Foundation

/// Epic 07 — thin UI-facing wrapper that runs a `QuickAction`, tracks
/// in-flight state on the source items (so the card can show a spinner),
/// and inserts derived items into the bucket.
///
/// Kept separate from `BucketManager` because actions are pure/async and
/// we want the manager to stay the @MainActor state holder — not a task
/// dispatcher.
@MainActor
enum BucketActionRunner {

    /// IDs of items currently being acted upon. `BucketCardView` observes
    /// `BucketManager.processingItemIDs` to overlay a spinner.
    static func run(
        _ type: any QuickAction.Type,
        items: [BucketItem],
        context: ActionContext,
        manager: BucketManager
    ) {
        let ids = items.map { $0.id }
        manager.markProcessing(ids: ids, processing: true)
        Task.detached(priority: .userInitiated) {
            do {
                let derived = try await type.perform(items, context: context)
                await MainActor.run {
                    // Insert derived items right after their source. If the
                    // source has been deleted mid-action, it falls back to
                    // head-insert.
                    for d in derived {
                        let sourceID = d.derivedFromItemID ?? context.destinationBucketID
                        manager.insertDerivedItem(
                            d,
                            afterSourceID: sourceID,
                            bucketID: context.destinationBucketID
                        )
                    }
                    manager.markProcessing(ids: ids, processing: false)
                }
            } catch {
                await MainActor.run {
                    manager.markProcessing(ids: ids, processing: false)
                    NotificationCenter.default.post(
                        name: .bucketActionFailed,
                        object: nil,
                        userInfo: [
                            "actionID": type.id,
                            "message": (error as? LocalizedError)?.errorDescription
                                ?? error.localizedDescription,
                        ]
                    )
                }
            }
        }
    }
}

extension Notification.Name {
    /// Posted when a `QuickAction.perform` throws. `userInfo`:
    ///   - `"actionID": String`
    ///   - `"message": String`
    /// Observed by AppDelegate to show a red bubble + log via `Log.app`.
    static let bucketActionFailed = Notification.Name("bucketActionFailed")

    /// Epic 07 — emitted when the user asks to jump to a derived item's
    /// source ("Reveal Source" context menu). `userInfo["itemID"]` is the
    /// source's UUID. `BucketView` listens and scrolls the matching card
    /// into view with a brief highlight.
    static let bucketRevealItem = Notification.Name("bucketRevealItem")
}
