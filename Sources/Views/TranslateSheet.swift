import SwiftUI

#if canImport(Translation)
import Translation
#endif

/// Epic 07 — SwiftUI sheet that translates a string via Apple's on-device
/// `Translation.framework`.
///
/// API note: Apple only exposes `TranslationSession` through the SwiftUI
/// `.translationTask` modifier on macOS 14.4 — you can't construct a session
/// programmatically. So translation lives in a view, not in `QuickAction`.
/// `BucketCardView` presents this sheet when the user picks "Translate to…",
/// and on success we call `BucketManager.shared.insertDerivedItem` to add a
/// new `.text` item next to the source.
///
/// Graceful degradation: gated by `#available(macOS 14.4, *)` at the call
/// site. Pre-14.4 the menu entry doesn't appear at all.
@available(macOS 15.0, *)
struct TranslateSheet: View {

    /// The text to translate — already extracted from the source item
    /// (plain text or OCR'd body).
    let sourceText: String

    /// The source item's ID — gets stamped into `TranslationMeta.sourceItemID`
    /// on the derived item so the UI can later offer "show original".
    let sourceItemID: UUID

    /// Bucket the derived item will be inserted into (typically the source's
    /// own bucket so translated text appears right next to its original).
    let bucketID: UUID

    let onFinished: () -> Void

    @State private var configuration: TranslationSession.Configuration?
    @State private var targetLang: Locale.Language = Locale.current.language
    @State private var availableTargets: [Locale.Language] = []
    @State private var isTranslating = false
    @State private var errorMessage: String?
    @State private var translatedText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Translate")
                    .font(.headline)
                Spacer()
                Button("Close") { onFinished() }
                    .keyboardShortcut(.cancelAction)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Source")
                    .font(.caption).foregroundStyle(.secondary)
                ScrollView { Text(sourceText).textSelection(.enabled) }
                    .frame(maxHeight: 90)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
            }

            HStack {
                Text("Translate to:")
                Picker("", selection: $targetLang) {
                    ForEach(availableTargets, id: \.self) { lang in
                        Text(Self.displayName(for: lang)).tag(lang)
                    }
                }
                .labelsHidden()
                .frame(width: 220)
            }

            if let translatedText, !translatedText.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Result")
                        .font(.caption).foregroundStyle(.secondary)
                    ScrollView { Text(translatedText).textSelection(.enabled) }
                        .frame(maxHeight: 90)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption).foregroundStyle(.red)
            }

            HStack {
                if isTranslating {
                    ProgressView().controlSize(.small)
                    Text("Translating…").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Translate") {
                    runTranslation()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isTranslating || sourceText.isEmpty)

                if translatedText != nil {
                    Button("Save to Bucket") {
                        persist()
                        onFinished()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(18)
        .frame(minWidth: 420, minHeight: 260)
        .task { await loadAvailableLanguages() }
        .translationTask(configuration) { session in
            await runSession(session)
        }
    }

    private func runTranslation() {
        errorMessage = nil
        translatedText = nil
        isTranslating = true
        // Poking the configuration triggers `.translationTask` to call our
        // closure with a ready-to-use session.
        configuration = TranslationSession.Configuration(
            source: nil,             // let Apple auto-detect
            target: targetLang
        )
    }

    private func runSession(_ session: TranslationSession) async {
        do {
            let response = try await session.translate(sourceText)
            await MainActor.run {
                translatedText = response.targetText
                isTranslating = false
            }
        } catch {
            await MainActor.run {
                errorMessage = "Translation failed: \(error.localizedDescription)"
                isTranslating = false
            }
        }
    }

    private func persist() {
        guard let translatedText, !translatedText.isEmpty else { return }
        let meta = TranslationMeta(
            detectedSourceLang: nil,
            targetLang: targetLang.minimalIdentifier,
            sourceItemID: sourceItemID
        )
        let derived = BucketItem(
            kind: .text,
            text: translatedText,
            derivedFromItemID: sourceItemID,
            derivedAction: "translate:\(targetLang.minimalIdentifier)",
            translationMeta: meta
        )
        BucketManager.shared.insertDerivedItem(
            derived,
            afterSourceID: sourceItemID,
            bucketID: bucketID
        )
    }

    private func loadAvailableLanguages() async {
        let availability = LanguageAvailability()
        let set = await availability.supportedLanguages
        // Sort by localized name; drop dialects for the top-level list to
        // keep the picker short. Users who need a specific regional variant
        // can set their system locale.
        let uniq = Array(Set(set.map { $0.languageCode?.identifier ?? $0.minimalIdentifier }))
            .compactMap { $0 }
            .map { Locale.Language(identifier: $0) }
        let sorted = uniq.sorted {
            Self.displayName(for: $0) < Self.displayName(for: $1)
        }
        await MainActor.run {
            availableTargets = sorted
            if !sorted.contains(targetLang) {
                targetLang = sorted.first ?? Locale.current.language
            }
        }
    }

    private static func displayName(for lang: Locale.Language) -> String {
        let id = lang.maximalIdentifier
        return Locale.current.localizedString(forLanguageCode: id) ?? id
    }
}
