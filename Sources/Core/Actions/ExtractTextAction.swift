import Foundation
import Vision
import ImageIO
import CoreGraphics

/// Vision-powered OCR for `.image` items. Produces two effects:
///
///   1. **Metadata writeback** — the *source* image's `ocrText`, `ocrLocale`
///      and `ocrIndexedAt` are populated via `BucketManager.updateOCR` so
///      the existing `search(_:)` can find the image by its text.
///   2. **Derived `.text` item** — the recognized string appears next to
///      the source in the bucket, ready to drag out or translate.
///
/// Runs entirely on-device via Vision's CPU/Neural-Engine pipeline. No
/// network, no API key. Locale defaults to user's preferred languages +
/// `en-US` so screenshots of English-language code still OCR well on a
/// non-English system.
enum ExtractTextAction: QuickAction {
    static let id = "extract-text"
    static let title = "Extract text"

    static func appliesTo(_ items: [BucketItem]) -> Bool {
        !items.isEmpty && items.allSatisfy { $0.kind == .image }
    }

    static func perform(_ items: [BucketItem], context: ActionContext) async throws -> [BucketItem] {
        guard !items.isEmpty else { throw QuickActionError.noInput }
        var out: [BucketItem] = []
        for item in items {
            try Task.checkCancellation()
            let recognized = try await recognize(item: item, context: context)
            // Writeback to the source happens on the @MainActor side because
            // BucketManager is main-actor-isolated. Defer to the caller.
            await MainActor.run {
                BucketManager.shared.updateOCR(
                    itemID: item.id,
                    text: recognized.text,
                    locale: recognized.locale
                )
            }
            // Don't create a derived `.text` item for empty OCR — nothing
            // useful to carry. The writeback still happens so search knows
            // the image has been indexed (via `ocrIndexedAt`).
            guard let body = recognized.text, !body.isEmpty else { continue }
            let derived = BucketItem(
                kind: .text,
                sourceBundleID: item.sourceBundleID,
                text: body,
                derivedFromItemID: item.id,
                derivedAction: Self.id
            )
            out.append(derived)
        }
        return out
    }

    // MARK: - Static helper reused by OCRIndex

    struct OCRResult: Sendable {
        var text: String?
        var locale: String?
    }

    /// Runs VNRecognizeTextRequest against the image pointed at by the
    /// item's `cachedPath`. Shared between `ExtractTextAction` (manual) and
    /// `OCRIndex` (auto) so both code paths produce identical results.
    ///
    /// Lives at file scope rather than inside the action enum so an actor
    /// (`OCRIndex`) can call it without hopping through the main actor.
    static func runOCR(
        imageAt url: URL,
        preferredLanguages: [String]? = nil
    ) async throws -> OCRResult {
        // Read bytes + build a CGImage. We deliberately avoid NSImage here
        // so the code is usable from a non-main actor.
        guard let data = try? Data(contentsOf: url) else {
            throw QuickActionError.missingFile(path: url.path)
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw QuickActionError.imageLoadFailed
        }

        let languages = preferredLanguages ?? Self.defaultLanguages()

        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { req, err in
                if let err {
                    continuation.resume(throwing: QuickActionError.visionFailed(err.localizedDescription))
                    return
                }
                let observations = (req.results as? [VNRecognizedTextObservation]) ?? []
                let lines = observations.compactMap {
                    // Epic 07 — confidence threshold default 0.3. Vision
                    // scores 0…1 per candidate; anything below 0.3 is
                    // typically noise (font anti-alias, logo marks, etc.).
                    // Exposed as a top-level constant so tests can tweak.
                    $0.topCandidates(1).first
                }
                .filter { $0.confidence >= ExtractTextAction.ocrConfidenceThreshold }
                .map { $0.string }
                let joined = lines.joined(separator: "\n")
                continuation.resume(returning: OCRResult(
                    text: joined.isEmpty ? nil : joined,
                    locale: languages.first
                ))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = languages

            let handler = VNImageRequestHandler(cgImage: cg, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: QuickActionError.visionFailed(error.localizedDescription))
            }
        }
    }

    /// Minimum per-line confidence (0…1) we trust. Lower values let more
    /// noise into search; higher values drop characters on blurry
    /// screenshots. 0.3 is the empirical sweet spot on macOS 14/15.
    static let ocrConfidenceThreshold: Float = 0.3

    private static func defaultLanguages() -> [String] {
        // `Locale.preferredLanguages` is BCP-47; Vision accepts the same format.
        var langs = Locale.preferredLanguages
        if !langs.contains(where: { $0.hasPrefix("en") }) {
            langs.append("en-US")
        }
        return langs
    }

    // MARK: - Private

    private static func recognize(
        item: BucketItem,
        context: ActionContext
    ) async throws -> OCRResult {
        guard let rel = item.fileRef?.cachedPath else {
            throw QuickActionError.missingFile(path: "<no cachedPath>")
        }
        let url = context.storeRootURL.appendingPathComponent(rel)
        return try await runOCR(imageAt: url)
    }
}
