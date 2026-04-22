import XCTest
@testable import SnorOhSwift

/// Epic 07 — unit tests for the quick-action foundations. Covers:
///   - Schema forward-compat (BucketItem decodes old JSON without the new fields)
///   - Search now matches images by `ocrText`
///   - `insertDerivedItem` lands a derived item right after its source
///   - `markProcessing` set updates on enter/exit
///   - QuickActionRegistry filtering
///   - Derived-name helper edge cases
///   - Settings round-trip for `ocrIndexingMode`
@MainActor
final class Epic07QuickActionsTests: XCTestCase {

    var tempRoot: URL!
    var manager: BucketManager!

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("epic07-test-\(UUID().uuidString)")
        let store = BucketStore(rootURL: tempRoot)
        manager = BucketManager(store: store)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempRoot)
        try await super.tearDown()
    }

    // MARK: - Forward-compat decode

    func testOldBucketItemJSONDecodesWithNilOCRFields() throws {
        // A payload captured before Epic 07 shipped — no ocrText / translationMeta.
        let json = """
        {
          "id": "\(UUID().uuidString)",
          "kind": "text",
          "createdAt": 753000000,
          "lastAccessedAt": 753000000,
          "pinned": false,
          "text": "legacy item"
        }
        """.data(using: .utf8)!
        let item = try JSONDecoder().decode(BucketItem.self, from: json)
        XCTAssertNil(item.ocrText)
        XCTAssertNil(item.ocrLocale)
        XCTAssertNil(item.ocrIndexedAt)
        XCTAssertNil(item.derivedFromItemID)
        XCTAssertNil(item.derivedAction)
        XCTAssertNil(item.translationMeta)
        XCTAssertEqual(item.text, "legacy item")
    }

    func testBucketSettingsDecodesMissingOCRModeAsLazy() throws {
        let json = """
        { "maxItems": 50 }
        """.data(using: .utf8)!
        let settings = try JSONDecoder().decode(BucketSettings.self, from: json)
        XCTAssertEqual(settings.ocrIndexingMode, .lazy,
                       "default mode must be .lazy so older installs get the new search behavior for free")
    }

    func testBucketSettingsRoundTripsOCRMode() throws {
        var settings = BucketSettings()
        settings.ocrIndexingMode = .eager
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(BucketSettings.self, from: data)
        XCTAssertEqual(decoded.ocrIndexingMode, .eager)
    }

    // MARK: - Search over OCR text

    func testSearchMatchesImageByOCRText() {
        let textItem = BucketItem(kind: .text, text: "some text content")
        var shot = BucketItem(kind: .image)
        shot.ocrText = "Screenshot of Unicorn Chart 2024"
        shot.ocrIndexedAt = Date()
        manager.add(textItem, source: .panel)
        manager.add(shot, source: .panel)

        let hits = manager.search("unicorn")
        XCTAssertEqual(hits.count, 1, "only the OCR'd image should match")
        XCTAssertEqual(hits.first?.id, shot.id)
    }

    func testSearchDoesNotMatchImageWithoutOCRText() {
        // Image has no ocrText → not findable via text search.
        let shot = BucketItem(kind: .image)
        manager.add(shot, source: .panel)
        XCTAssertTrue(manager.search("anything").isEmpty)
    }

    func testSearchOnlyUsesOCRTextForImages() {
        // Non-image items never consult ocrText even if set (defense in
        // depth — spec says images only).
        var odd = BucketItem(kind: .text, text: "visible")
        odd.ocrText = "SECRET"
        manager.add(odd, source: .panel)
        XCTAssertTrue(manager.search("secret").isEmpty,
                      "OCR field only applies to .image kind")
        XCTAssertEqual(manager.search("visible").count, 1)
    }

    // MARK: - updateOCR writeback

    func testUpdateOCRStampsIndexedAtEvenOnEmptyResult() {
        let shot = BucketItem(kind: .image)
        manager.add(shot, source: .panel)
        manager.updateOCR(itemID: shot.id, text: nil, locale: "en-US")
        let item = manager.activeBucket.items.first { $0.id == shot.id }!
        XCTAssertNil(item.ocrText)
        XCTAssertNotNil(item.ocrIndexedAt,
                        "empty OCR must still stamp ocrIndexedAt so we don't re-try forever")
        XCTAssertEqual(item.ocrLocale, "en-US")
    }

    // MARK: - insertDerivedItem

    func testInsertDerivedItemLandsImmediatelyAfterSource() {
        let first  = BucketItem(kind: .text, text: "first")
        let source = BucketItem(kind: .image)
        let last   = BucketItem(kind: .text, text: "last")

        manager.add(last, source: .panel)
        manager.add(source, source: .panel)
        manager.add(first, source: .panel)
        // Order (newest at head): first, source, last

        let derived = BucketItem(kind: .text, text: "resized@50")
        manager.insertDerivedItem(
            derived,
            afterSourceID: source.id,
            bucketID: manager.activeBucketID
        )

        let items = manager.activeBucket.items
        let sourceIdx = items.firstIndex { $0.id == source.id }!
        XCTAssertEqual(items[sourceIdx + 1].text, "resized@50")
        XCTAssertEqual(items[sourceIdx + 1].derivedFromItemID, source.id)
    }

    func testInsertDerivedItemFallsBackToHeadWhenSourceGone() {
        manager.add(BucketItem(kind: .text, text: "already here"), source: .panel)
        let missingID = UUID()
        let derived = BucketItem(kind: .text, text: "orphan")
        manager.insertDerivedItem(
            derived,
            afterSourceID: missingID,
            bucketID: manager.activeBucketID
        )
        XCTAssertEqual(manager.activeBucket.items.first?.text, "orphan",
                       "derived item falls back to head when source no longer exists")
    }

    // MARK: - markProcessing

    func testMarkProcessingTogglesSet() {
        let id = UUID()
        XCTAssertFalse(manager.processingItemIDs.contains(id))
        manager.markProcessing(ids: [id], processing: true)
        XCTAssertTrue(manager.processingItemIDs.contains(id))
        manager.markProcessing(ids: [id], processing: false)
        XCTAssertFalse(manager.processingItemIDs.contains(id))
    }

    // MARK: - QuickActionRegistry

    func testRegistryFiltersByAppliesTo() {
        let text  = BucketItem(kind: .text, text: "x")
        let image = BucketItem(kind: .image)

        let forText = QuickActionRegistry.actionsApplying(to: [text])
        XCTAssertTrue(forText.contains { $0.id == ExtractTextAction.id } == false,
                      "ExtractText only applies to images")
        XCTAssertFalse(forText.contains { $0.id == ResizeImageAction.id },
                       "Resize shouldn't apply to pure text")

        let forImage = QuickActionRegistry.actionsApplying(to: [image])
        XCTAssertTrue(forImage.contains { $0.id == ResizeImageAction.id })
        XCTAssertTrue(forImage.contains { $0.id == ExtractTextAction.id })
        XCTAssertTrue(forImage.contains { $0.id == StripExifAction.id })
    }

    func testRegistryFindByID() {
        XCTAssertNotNil(QuickActionRegistry.find(id: ResizeImageAction.id))
        XCTAssertNotNil(QuickActionRegistry.find(id: ExtractTextAction.id))
        XCTAssertNil(QuickActionRegistry.find(id: "bogus-action-xyz"))
    }

    // MARK: - makeDerivedName

    func testDerivedNameSuffixInsert() {
        XCTAssertEqual(makeDerivedName(original: "photo.jpg", suffix: "@50%"),
                       "photo@50%.jpg")
        XCTAssertEqual(makeDerivedName(original: "screenshot.png", suffix: "-clean"),
                       "screenshot-clean.png")
    }

    func testDerivedNameExtensionReplace() {
        XCTAssertEqual(makeDerivedName(original: "photo.jpg", suffix: ".png"),
                       "photo.png")
        XCTAssertEqual(makeDerivedName(original: "photo.jpg", suffix: ".heic"),
                       "photo.heic")
    }

    func testDerivedNameHandlesMissingOriginal() {
        XCTAssertEqual(makeDerivedName(original: nil, suffix: "@50%"),
                       "derived@50%")
        XCTAssertEqual(makeDerivedName(original: "", suffix: "-clean"),
                       "derived-clean")
    }

    func testDerivedNameHandlesNoExtension() {
        XCTAssertEqual(makeDerivedName(original: "document", suffix: "-v2"),
                       "document-v2")
    }

    // MARK: - Action error surface

    func testResizeActionThrowsOnEmptyInput() async {
        let ctx = ActionContext(
            storeRootURL: tempRoot,
            store: BucketStore(rootURL: tempRoot),
            destinationBucketID: manager.activeBucketID
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await ResizeImageAction.perform([], context: ctx)
        }
    }

    func testExtractTextActionRejectsNonImages() {
        let textItem = BucketItem(kind: .text, text: "not an image")
        XCTAssertFalse(ExtractTextAction.appliesTo([textItem]))
    }

    func testConvertActionRejectsUnsupportedFormat() async {
        let image = BucketItem(
            kind: .image,
            fileRef: BucketItem.FileRef(
                originalPath: "",
                cachedPath: "nonexistent.png",
                byteSize: 0,
                uti: "public.png",
                displayName: "nonexistent.png"
            )
        )
        var ctx = ActionContext(
            storeRootURL: tempRoot,
            store: BucketStore(rootURL: tempRoot),
            destinationBucketID: manager.activeBucketID
        )
        ctx.params["format"] = "gif" // unsupported
        await XCTAssertThrowsErrorAsync {
            _ = try await ConvertImageAction.perform([image], context: ctx)
        }
    }

    // MARK: - Status enum stays additive

    func testTranslateNotInRegistry() {
        // Translate is a SwiftUI sheet, not a QuickAction — registry must
        // never surface it or the menu wiring would crash trying to invoke
        // a non-existent `perform` path.
        let ids = QuickActionRegistry.all.map { $0.id }
        XCTAssertFalse(ids.contains("translate"),
                       "Translate is sheet-based, not registry-based")
    }
}

// MARK: - Async throws helper

func XCTAssertThrowsErrorAsync(
    _ expression: @escaping () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected throw", file: file, line: line)
    } catch {
        // expected
    }
}
