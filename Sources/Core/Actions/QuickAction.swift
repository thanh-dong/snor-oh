import Foundation

/// Epic 07 — one-tap transforms on bucket items (resize, convert, OCR,
/// translate, strip EXIF, …).
///
/// **Contract**:
///   - Non-destructive: the source item(s) are never mutated. Actions that
///     index an image (OCR) write back to the *source* via
///     `BucketManager.updateOCR`, which is a metadata-only update; pixels
///     stay untouched.
///   - Additive: a successful `perform` returns zero or more *new* items.
///     Callers insert them via `BucketManager.insertDerivedItem(_:afterSourceID:bucketID:source:)`
///     so they appear next to their source rather than at the head.
///   - Cancellable: `perform` is `async throws` and honors `Task` cancellation.
///   - Local: nothing networks. Translation uses Apple's on-device
///     `Translation.framework`; OCR uses Vision; image ops use ImageIO.
///
/// Implementations live alongside this file (`Sources/Core/Actions/*.swift`).
/// The registry is string-keyed so new actions don't need a schema bump.
protocol QuickAction: Sendable {
    /// Stable identifier. Stamped into derived items' `derivedAction` field
    /// and used by the context-menu wiring. Must not change across releases.
    static var id: String { get }

    /// Human-readable menu title.
    static var title: String { get }

    /// Fast pre-filter: does this action apply to the selected items? UI
    /// hides the action when this returns false.
    static func appliesTo(_ items: [BucketItem]) -> Bool

    /// Runs the transform. MUST be side-effect-free on the source items
    /// (metadata writebacks go through `ActionContext`). Throws
    /// `QuickActionError` on failure.
    static func perform(_ items: [BucketItem], context: ActionContext) async throws -> [BucketItem]
}

/// Environment passed into every action. Carries the store-root so actions
/// can resolve sidecar files for reads, and the store actor so they can
/// persist derived bytes to the sidecar tree without each action needing
/// its own disk plumbing.
struct ActionContext: Sendable {
    /// Root directory of the on-disk sidecar tree
    /// (`~/.snor-oh/buckets/<bucket-id>/…`). Actions join relative
    /// `fileRef.cachedPath` onto this to read bytes.
    let storeRootURL: URL

    /// Bucket-scoped disk writer. Actions call `await store.writeSidecar(…)`
    /// to persist derived bytes and get back a relative path they embed in
    /// the returned `BucketItem.fileRef.cachedPath`.
    let store: BucketStore

    /// Destination bucket for derived items. Callers usually pass
    /// `BucketManager.shared.activeBucketID`.
    let destinationBucketID: UUID

    /// Optional target-language code (BCP-47). Used only by
    /// `TranslateAction`; other actions ignore it.
    var targetLanguageCode: String?

    /// Optional user-tweaked parameters:
    /// - Resize: `["scale": "0.5"]` for 50%
    /// - Convert: `["format": "jpeg"]` / `"heic"` / `"png"`
    /// - JPEG quality on convert: `["quality": "0.85"]`
    var params: [String: String] = [:]
}

/// All errors surface through here so the UI layer can render a consistent
/// red speech bubble and log via `Log.app`.
enum QuickActionError: Error, LocalizedError, Sendable {
    case noInput
    case unsupportedItemKind(BucketItemKind)
    case missingFile(path: String)
    case imageLoadFailed
    case imageEncodeFailed
    case visionFailed(String)
    case translationUnavailable
    case translationLanguagePairMissing(source: String?, target: String)
    case translationSessionFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noInput: return "No items selected"
        case .unsupportedItemKind(let k): return "Action doesn't support \(k.rawValue)"
        case .missingFile(let p): return "File not found: \(p)"
        case .imageLoadFailed: return "Could not read image"
        case .imageEncodeFailed: return "Could not encode result image"
        case .visionFailed(let m): return "OCR failed: \(m)"
        case .translationUnavailable: return "Translation requires macOS 14.4 or later"
        case .translationLanguagePairMissing(let s, let t):
            return "Language pack \(s ?? "auto")→\(t) isn't installed"
        case .translationSessionFailed(let m): return "Translation failed: \(m)"
        case .cancelled: return "Action cancelled"
        }
    }
}

/// String-keyed registry. Menu builders iterate this and call `appliesTo`
/// to decide which entries to surface. Order here is the menu order.
enum QuickActionRegistry {
    /// The `any QuickAction.Type` erasure lets us hold heterogenous concrete
    /// types in one array while still keeping each action a non-generic
    /// enum/struct with static methods.
    ///
    /// **Not in the registry**:
    /// - "Copy as plain text" — inline clipboard side-effect (no derived
    ///   item), handled directly in `BucketCardView`'s context menu.
    /// - "Translate to…" — needs a SwiftUI `.translationTask` modifier to
    ///   obtain a `TranslationSession` (Apple API shape, not our choice),
    ///   so it's implemented as a sheet view (`TranslateSheet`) rather
    ///   than a pure async function. UI layer gates with
    ///   `if #available(macOS 15.0, *)` — the programmatic translation
    ///   API is 15.0+ (14.4 only ships the system-UI `.translationPresentation`
    ///   modifier, which doesn't return a string we can persist).
    static let all: [any QuickAction.Type] = [
        ResizeImageAction.self,
        ConvertImageAction.self,
        StripExifAction.self,
        ExtractTextAction.self,
    ]

    /// Convenience: actions that apply to the given selection, preserving
    /// registry order.
    static func actionsApplying(to items: [BucketItem]) -> [any QuickAction.Type] {
        all.filter { $0.appliesTo(items) }
    }

    /// Look up by string id. Used when the UI wants to invoke a specific
    /// action (e.g. from a keyboard shortcut).
    static func find(id: String) -> (any QuickAction.Type)? {
        all.first { $0.id == id }
    }
}
