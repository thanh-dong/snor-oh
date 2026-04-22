# Epic 07 — Quick Actions on Items

**Tier**: 🔵 v2 power-user · **Complexity**: M–L (2–3 weeks) · **Depends on**: Epic 01

*Revision 2026-04-22*: added Translation action (Apple `Translation.framework`) and OCR-powered image search to Musts. Removed "translate" from Won't — Apple ships an on-device translator, so it fits the "local processing only" rule we set in v1.

## Problem Statement

Dropover's "Instant Actions" — resize image, stitch PDFs, extract text, compress, share — are the #1 upsell in its marketing and a top power-user favorite across reviews ([research §Should-Have/Nice-to-Have](../../research/bucket-feature-research.md)). Once you have an image in the bucket, you often want to do *one* thing with it before sending it somewhere else (shrink it for email, flip to JPG, crop, OCR the text). Opening Preview.app breaks flow.

**Plus two research-follow-ups we deferred from v1:**

- **Searchable screenshots.** Users dump dozens of screenshots a day into the bucket. Today the only way to find one is to scroll — the image blobs have no textual handle. Apple's Vision OCR is cheap and on-device, so if we're already shipping "Extract text" as an action, using its output to make images findable is nearly free.
- **Quick translation.** Between reading docs, pasting snippets from foreign-language sources, and replying to global teammates, a "translate this clip to English" gesture is the most-requested text action across clipboard-manager threads. Apple added `Translation.framework` in macOS 14.4 — on-device, free, no API key — which lets us offer this without crossing the "we don't ship AI features" line.

## Hypothesis

> We believe **a small menu of one-tap actions on bucket items** will dramatically increase drag-out-and-use rate vs drag-out-and-abandon. We'll know we're right when ≥20% of drops from the bucket are preceded by a quick action.

## Scope (MoSCoW)

Shipping a curated set. Pass if it's boring, fail if it's niche.

| Priority | Action | Applies to | Why |
|---|---|---|---|
| Must | Resize image (50% / 25% / custom) | image | Most common need |
| Must | Convert image format (PNG / JPG / HEIC) | image | File-attach compatibility |
| Must | Copy as plain text | text, richText | Universal pain point |
| Must | Extract text from image (Vision framework OCR) | image | Cheap with Apple's built-in |
| Must | **Translate to…** (on-device, Apple `Translation.framework`) | text, richText, image (via OCR) | Top-requested text action; no AI-cloud tradeoff |
| Must | **Search images by OCR'd text content** | image (auto or lazy) | Turns screenshots from scroll-only into findable |
| Must | Open with default app | all | Escape valve |
| Must | Share link (Dropover-cloud-style short URL) | all (opt-in service) | See "Deferred" below |
| Should | Rename item | all | Bucket hygiene |
| Should | Compress to ZIP (single or stack) | file, folder | Send-as-attachment flow |
| Should | Stitch multiple PDFs / images into one PDF | ≥2 selected PDFs or images | Power-user favorite |
| Should | Strip EXIF metadata | image | Privacy |
| Should | **Detect source language on translate** (hint + confidence) | text, richText | Reduces "select source" clicks |
| Could | Rotate image | image | Minor |
| Could | Convert PDF to images | file (.pdf) | Minor |
| Could | **Batch-translate** a multi-select set in one pass | text, richText | Pro user niche |
| Won't | AI-powered actions that require cloud (caption, summarize) | | Not our product |
| Won't | Video transcoding | | Too much scope |
| Won't | Background removal (Droppy's feature) | | Punt |
| Won't | Full-content image semantic search (CLIP-style) | | Needs on-device model shipping — separate epic |

**Deferred**: "Share link" needs a hosted service for public URLs. In v1 of this epic, implement as: "copy item to clipboard as file-URL" plus optional integration with user's existing Dropbox/iCloud Drive/S3 via `rclone`-style configured target. Full hosted share link is its own epic.

## Users & JTBD

**Primary**: designers shrinking mocks for Figma comments, devs attaching logs to tickets, anyone emailing a photo.

**JTBD**: *When an item in my bucket needs one transform before it leaves, I want to do it inline without opening another app.*

## User Stories

1. I right-click a 4032×3024 iPhone photo → Resize → 50% → a new item appears in the bucket with the smaller version; original preserved.
2. I select 3 PDFs in the bucket → right-click → "Stitch to PDF" → a single combined PDF appears.
3. I right-click a screenshot of code → "Extract text" → the recognized text becomes a new `text` item in the bucket.
4. I select a file → "Compress to ZIP" → a `.zip` item appears, ready to drag out.
5. I paste a Japanese paragraph in the bucket → right-click → Translate to → English → a new `text` item appears with the translation; the original stays pinned.
6. I dropped 30 screenshots of a WWDC talk earlier. I hit ⌃⌥B, type `interfaces` into bucket search, and the two slides that contain that word surface first — no OCR button clicked, no wait.
7. I OCR a receipt in Vietnamese → right-click the resulting text item → Translate to → English → I now have both texts side-by-side in the bucket.

## UX Flow

```
Right-click item card → context menu:
  Quick Look
  Rename
  Copy as plain text
  ─────────────
  Actions ▸
    Resize image ▸
      50%
      25%
      Custom...
    Convert to ▸
      PNG
      JPG
      HEIC
    Extract text
    Translate to ▸                (text / richText / image-with-OCR only)
      English
      ── Recent ──
      Japanese
      Vietnamese
      ── All supported ▸
    Strip EXIF
    Compress to ZIP
    Stitch with... ▸       (only if ≥1 other PDF/image)
  ─────────────
  Open with default
  Share link
  ─────────────
  Pin
  Move to ▸
  Delete
```

Multi-select (⌘+click / ⇧+click) enables the batch actions (Compress to ZIP, Stitch).

## Acceptance Criteria

- [ ] Actions run off `@MainActor` on a background `Task` when processing >1 MB or multiple files
- [ ] Result items preserve source item's provenance (new item's metadata records "derived from <source-item-id>")
- [ ] Original item never destructively modified
- [ ] Each action shows progress if it takes >500 ms (spinner on the source card)
- [ ] Resize: preserves aspect, uses `vImage` high-quality scaling
- [ ] Convert: uses `ImageIO` — supports PNG, JPEG, HEIC, TIFF
- [ ] Extract text: uses `VNRecognizeTextRequest` with `.accurate` mode, en-US + user's locale
- [ ] Extract text result writes back to `item.ocrText` on the source image (so search can find it), AND creates a new derived `.text` item (user-visible result)
- [ ] Compress: standard deflate .zip via `Compression` or shell out to `zip`
- [ ] Stitch PDFs: uses `PDFKit.PDFDocument.insert(_:at:)`
- [ ] Strip EXIF: removes everything except orientation
- [ ] **Translate**: uses `Translation.framework` (`TranslationSession` / `LanguageAvailability`), on-device only, no network ever. Gated by `#available(macOS 14.4, *)` — the action is hidden on older OSes rather than shown as disabled.
- [ ] **Translate**: if the required language pair isn't downloaded yet, the user is prompted once to download via Apple's system UI. Subsequent calls complete without prompt.
- [ ] **Translate**: writes a new derived item with `derivedAction = "translate:<source>→<target>"` and metadata recording detected source language + target language.
- [ ] **Search by OCR text**: `BucketManager.search(_:)` matches against `item.ocrText` for image items in addition to existing fields. Case-insensitive, substring match — same semantics as other item fields.
- [ ] **OCR indexing mode** is configurable in Settings → Bucket → "Index screenshots for search": `eager` / `lazy` / `manual`. Default `lazy` (see §OCR Indexing for trade-offs).
- [ ] Actions never network — all local-processing only (this epic)
- [ ] Errors surface as a red speech bubble + log via `Log.app`

## Data Model

Additive fields on `BucketItem` — all optional, all default-nil, so existing
on-disk JSON decodes without migration.

```swift
public struct BucketItem {
    // existing ...
    public var derivedFromItemID: UUID?        // set when created by a quick action
    public var derivedAction: String?          // e.g. "resize:50", "extractText",
                                               //      "translate:ja→en", "stitch"

    // Epic 07 — OCR-powered search
    public var ocrText: String?                // only set for .image items that
                                               // have been OCR'd (manual or auto)
    public var ocrLocale: String?              // BCP-47; the `Locale` OCR was
                                               // run with, so we can re-OCR if
                                               // the user changes system lang
    public var ocrIndexedAt: Date?             // sentinel for "already OCR'd";
                                               // also lets the sweep re-run
                                               // when the OS bumps Vision
}
```

New optional derived-item metadata when the action is a translation:

```swift
public struct TranslationMeta: Codable, Sendable {
    let detectedSourceLang: String?   // BCP-47, nil when user pre-specified
    let targetLang: String            // BCP-47
    let sourceItemID: UUID
}

public struct BucketItem {
    // ...
    public var translationMeta: TranslationMeta?
}
```

No new top-level types. Actions are implemented as pure functions returning a new `BucketItem`.

### Backward-compat rule (carrying forward from Epic 02)

Same principle as `Status.spriteStatuses` — any new required field on a
serialized type must be optional with a safe default. The OCR fields and
`translationMeta` are all optional; older builds decoding newer `.json`
payloads silently ignore them and newer builds decoding older payloads see
`nil` and fall back to "not OCR'd yet". No schema version bump needed.

## Action Interface

```swift
// Sources/Core/Actions/QuickAction.swift

public protocol QuickAction {
    static var id: String { get }
    static var title: String { get }
    static func appliesTo(_ items: [BucketItem]) -> Bool
    static func perform(_ items: [BucketItem], context: ActionContext) async throws -> [BucketItem]
}

public struct ActionContext: Sendable {
    let bucketStore: BucketStore
    let destinationBucketID: UUID
}

// Example:
public enum ResizeImageAction: QuickAction {
    public static var id = "resize-image"
    public static var title = "Resize image"

    public static func appliesTo(_ items: [BucketItem]) -> Bool {
        items.allSatisfy { $0.kind == .image }
    }

    public static func perform(_ items: [BucketItem], context: ActionContext) async throws -> [BucketItem] {
        // ...
    }
}
```

Registry:

```swift
public enum QuickActionRegistry {
    public static let all: [any QuickAction.Type] = [
        ResizeImageAction.self,
        ConvertImageAction.self,
        ExtractTextAction.self,
        TranslateAction.self,            // Epic 07 rev — on-device translation
        StripExifAction.self,
        CompressZipAction.self,
        StitchPDFAction.self,
        CopyAsPlainTextAction.self,
        RenameAction.self,
    ]
}
```

## OCR Indexing

OCR is cheap (~200–500 ms per screenshot on M-series, ~1s on Intel) but not
free — running it on every image drop is wasted work if the user never searches
that image. The three viable modes:

| Mode | When OCR runs | First search latency | CPU burn | Storage | Best for |
|---|---|---|---|---|---|
| `eager` | On every image add, background `Task.detached(priority: .utility)` | Instant | ~0.3 s × N images × 1 | `ocrText` per image | Users who screenshot constantly, always search |
| `lazy` | On first search that types >2 chars against an un-OCR'd image | ~0.3 s × untouched images (one-shot, cached after) | Minimal, on-demand | Same (cached after first search) | Default — most users |
| `manual` | Only when user clicks "Extract text" | N/A — image never matches text search unless OCR'd | Zero | Only user-OCR'd images | Privacy-conscious / battery-sensitive |

**Lean: default `lazy`.** Reasons:
1. Zero CPU burn until the user actually searches — respects battery on laptops.
2. First-search cost is still <1s for a typical bucket of 20 images (batch with `TaskGroup`, results cached to `ocrText`).
3. `eager` can be a user opt-in later if data shows people search >50% of their screenshots.
4. `manual` matches Dropover's behavior but loses the "searchable screenshots" wow factor.

`lazy` mode pseudocode:

```swift
// Sources/Core/Actions/OCRIndex.swift

actor OCRIndex {
    func ensureIndexed(items: [BucketItem]) async {
        let pending = items.filter {
            $0.kind == .image && $0.ocrText == nil
        }
        await withTaskGroup(of: (UUID, String?).self) { group in
            for item in pending {
                group.addTask { (item.id, await runVisionOCR(item)) }
            }
            for await (id, text) in group {
                await BucketManager.shared.updateOCR(id: id, text: text)
            }
        }
    }
}

// Search integration:
func search(_ q: String) async -> [BucketItem] {
    await OCRIndex.shared.ensureIndexed(items: activeBucket.items)
    // now ocrText is populated — existing substring matcher just works
    return activeBucket.items.filter { matches($0, q) }
}
```

Acceptance for OCR indexing:
- [ ] `lazy` mode: typing a query in `BucketView` search field triggers OCR for any image without `ocrText`; spinner overlays those cards during the run
- [ ] Once OCR'd, results persist — subsequent searches are instant
- [ ] Setting toggle hot-applies (changing from `lazy` → `eager` immediately queues a sweep of un-indexed images)

## Translation

`Translation.framework` entrypoint:

```swift
// Sources/Core/Actions/TranslateAction.swift

@available(macOS 14.4, *)
public enum TranslateAction: QuickAction {
    public static var id = "translate"
    public static var title = "Translate to…"

    public static func appliesTo(_ items: [BucketItem]) -> Bool {
        items.allSatisfy { item in
            item.kind == .text
                || item.kind == .richText
                || (item.kind == .image && item.ocrText?.isEmpty == false)
        }
    }

    public static func perform(_ items: [BucketItem], context: ActionContext) async throws -> [BucketItem] {
        let target = context.chosenLanguage ?? Locale.current.language
        return try await withThrowingTaskGroup(of: BucketItem.self) { group in
            for item in items {
                group.addTask {
                    try await translateOne(item, to: target)
                }
            }
            var out: [BucketItem] = []
            for try await item in group { out.append(item) }
            return out
        }
    }
}
```

Key decisions already locked in from Apple's API shape:
- **No API keys.** Translation runs on-device after a one-time per-language-pair download that Apple handles through its own UI.
- **Language availability check** runs before `perform`. If the pair isn't installed, we hand off to `.translationPresentation(...)` which shows Apple's download prompt; the user dismisses or accepts without us rendering any UI of our own.
- **Source-language detection** defaults to automatic. If detection confidence is low we fall back to `Locale.current` and surface the guess in the derived item's `translationMeta`.
- **Target languages** come from `LanguageAvailability.supportedLanguages`. UI surface: the top 3 "recent targets" + "All supported…" disclosure — see context-menu mock.

Graceful degradation on macOS <14.4: the Translate submenu simply doesn't appear (gated by `#available`), and the feature shows up in the release notes as "macOS 14.4+ only" without any disabled-menu noise.

## Implementation Notes

| Concern | Fit |
|---|---|
| Long-running tasks | `Task.detached` with explicit `@MainActor` hop on completion to update `BucketManager` |
| Image pipeline | `ImageIO` + `CoreImage` for conversion and resize. Matches existing SpriteCache image patterns. |
| OCR | Framework: `Vision`. Localization: follow user's `Locale.current` + en. Results: Copy as a new `.text` item. |
| PDF stitch | `PDFKit` — import of framework already exists if any PDF handling is in place; otherwise it's a system framework, no build change |
| Progress | Add `isProcessing: Bool` to `BucketItem` as transient (non-Codable) or a parallel `Set<UUID>` in `BucketManager.processingItemIDs` |
| Menu building | Use `onRightClick` → SwiftUI Menu, dynamically filtered by `appliesTo` |
| Multi-select | Extend `BucketItemCard` to participate in a selection set held by `BucketView` |

**Concurrency**: action `perform` is `async`. Each action uses `Task.detached(priority: .userInitiated)` and awaits. Swift 6 strict — no shared mutable state leaks.

## Out of Scope

- Cloud-based AI actions (caption, summarize via an external model) — still off the table
- Video transcoding / encoding
- Cloud share service with hosted URLs — separate epic (needs backend decision)
- Background removal (visual ML)
- Batch rename with regex / patterns
- "Watch folder and auto-act" — that's Epic 08's watched folders
- Custom user-defined actions / scripts
- **Semantic image search** (CLIP / embeddings) — out of scope; this epic is text-in-image only. If users want "find screenshots of a graph", that's a future epic that has to ship an on-device model.
- **Translation of files** (.pdf / .docx as a whole document) — this epic only translates text items and OCR'd image text. Document translation is a separate scope.

## Open Questions

- [ ] Default JPEG quality on convert — 85 or 90? (Lean: 85, tweakable in settings)
- [ ] Should derived items be auto-pinned so the source can expire? (Lean: no, user decides)
- [ ] OCR result gets a new item; should the source screenshot remain? (Lean: yes, always non-destructive)
- [ ] Action telemetry — worth tracking which actions are used? (Lean: yes, anonymous counter per `QuickAction.id`)
- [ ] **OCR default mode** — `lazy`, `eager`, or `manual`? (Lean: `lazy` — see §OCR Indexing; revisit after 2 weeks of data)
- [ ] **Translate default target language** — `Locale.current.language`, or force user to pick once? (Lean: `Locale.current`, override per-action via submenu)
- [ ] **Should translated items auto-pin?** Users often paste the translation then toss the source; auto-pin the translation so clear-all doesn't nuke it. (Lean: yes, pin the derived translated item; user unpins if unwanted)
- [ ] **OCR storage size** — `ocrText` can be long (code screenshots). Cap at, say, 10k chars? (Lean: no cap, but strip whitespace-only runs before persist)
- [ ] **Cross-session OCR invalidation** — if the user changes system language, do we re-OCR? (Lean: no; the `ocrLocale` field is recorded so a future "re-index in new language" action is possible but not this epic)

## Rollout Plan

Group actions into shippable batches:

| # | Batch | Actions | Status |
|---|------|---------|--------|
| 1 | Image basics | Resize (ImageIO thumbnail), Convert (PNG/JPEG/HEIC), Strip EXIF | ✅ |
| 2 | Text helpers | OCR extract text with write-back to `ocrText` + derived `.text` item | ✅ |
| 3 | **OCR-powered search** | `BucketManager.search` extended to image `ocrText`; `OCRIndex` actor (bounded-parallel 4); Settings toggle (`lazy` default) | ✅ |
| 4 | **Translation** | `TranslateSheet` SwiftUI view via `.translationTask` (macOS 15+); `TranslationMeta` persisted; graceful degradation pre-15 | ✅ |
| 5 | File ops | Compress ZIP, Rename | ☐ (deferred follow-up) |
| 6 | PDF power | Stitch PDFs | ☐ (deferred follow-up) |
| 7 | Context menu wiring | `BucketCardView.Actions ▸` submenu + Translate sheet trigger | ✅ |
| 8 | Progress + error UX | `BucketActionRunner` + per-card spinner overlay + `.bucketActionFailed` bubble | ✅ |
| 9 | Release build verify | 216/216 tests · universal binary signed · `.build/release-app/snor-oh.app` | ✅ |

**Revision 2026-04-22 notes**:
- **macOS gating shifted from 14.4 → 15.0** for the Translate feature. Compiler pointed out that `TranslationSession`, `LanguageAvailability`, and `.translationTask` are macOS 15+ APIs; 14.4 only ships the system-UI `.translationPresentation` modifier, which doesn't return a translated string we can persist.
- **Multi-select deferred.** The PRD mentions batch Compress/Stitch via ⌘/⇧ click; shipping single-item actions first keeps the context-menu wiring simple. All action implementations already take `[BucketItem]`, so adding multi-select is a UI-only follow-up.
- **OCR default is `.lazy`** (per PRD lean). Settings panel has Eager / Lazy / Manual segmented picker.

Ship each batch independently — no dependencies between batches.

## Success Metrics

| Metric | Target | Method |
|---|---|---|
| Quick-action invocation rate per 10 bucket drags | ≥2 | Action counter |
| % of drops-out that were preceded by an action | ≥20% | Drop-out timestamp minus last action timestamp <60s |
| Most-used action share | Top 1 ≥30% | Histogram; confirms we're shipping the right ones |
| Action failure rate | <3% | Exception / error counter |
| **Search queries that surface image matches** | ≥15% of all searches | Search log — search text ∩ ocrText |
| **Translation action usage (among users who have ≥1 non-English item)** | ≥30% | Language-specific counter |
| **Lazy-OCR first-search latency p95** | <1.5 s | Wall-clock timing around `OCRIndex.ensureIndexed` |
