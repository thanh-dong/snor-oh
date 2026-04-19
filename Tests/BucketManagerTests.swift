import XCTest
@testable import SnorOhSwift

@MainActor
final class BucketManagerTests: XCTestCase {

    var tempRoot: URL!
    var manager: BucketManager!

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("bucket-mgr-test-\(UUID().uuidString)")
        let store = BucketStore(rootURL: tempRoot)
        manager = BucketManager(store: store)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempRoot)
        try await super.tearDown()
    }

    // MARK: - add / remove / pin / clear

    func testAddInsertsAtHead() {
        let a = BucketItem(kind: .text, text: "first")
        let b = BucketItem(kind: .text, text: "second")
        manager.add(a, source: .panel)
        manager.add(b, source: .panel)
        XCTAssertEqual(manager.activeBucket.items.count, 2)
        XCTAssertEqual(manager.activeBucket.items.first?.text, "second")
    }

    func testAddPostsBucketChangedWithSource() {
        let exp = expectation(forNotification: .bucketChanged, object: nil) { note in
            let info = note.userInfo ?? [:]
            return info["source"] as? String == "clipboard"
                && info["change"] as? String == "added"
        }
        manager.add(BucketItem(kind: .text, text: "x"), source: .clipboard)
        wait(for: [exp], timeout: 0.2)
    }

    func testRemoveByID() {
        let item = BucketItem(kind: .text, text: "toremove")
        manager.add(item, source: .panel)
        manager.remove(id: item.id)
        XCTAssertTrue(manager.activeBucket.items.isEmpty)
    }

    func testTogglePinFlipsFlag() {
        let item = BucketItem(kind: .text, text: "x")
        manager.add(item, source: .panel)
        XCTAssertFalse(manager.activeBucket.items[0].pinned)
        manager.togglePin(id: item.id)
        XCTAssertTrue(manager.activeBucket.items[0].pinned)
        manager.togglePin(id: item.id)
        XCTAssertFalse(manager.activeBucket.items[0].pinned)
    }

    func testClearUnpinnedKeepsPinnedOnes() {
        let a = BucketItem(kind: .text, text: "keep")
        let b = BucketItem(kind: .text, text: "drop")
        manager.add(a, source: .panel)
        manager.add(b, source: .panel)
        manager.togglePin(id: a.id)  // pin "keep"
        manager.clearUnpinned()
        XCTAssertEqual(manager.activeBucket.items.count, 1)
        XCTAssertEqual(manager.activeBucket.items[0].text, "keep")
    }

    // MARK: - Clipboard dedupe

    func testConsecutiveIdenticalTextDeduped() {
        manager.add(BucketItem(kind: .text, text: "hello"), source: .clipboard)
        manager.add(BucketItem(kind: .text, text: "hello"), source: .clipboard)
        XCTAssertEqual(manager.activeBucket.items.count, 1)
    }

    func testDifferentKindsNotDeduped() {
        manager.add(BucketItem(kind: .text, text: "abc"), source: .clipboard)
        manager.add(BucketItem(kind: .color, colorHex: "abc"), source: .clipboard)
        XCTAssertEqual(manager.activeBucket.items.count, 2)
    }

    func testNonAdjacentDuplicatesAllowed() {
        manager.add(BucketItem(kind: .text, text: "a"), source: .clipboard)
        manager.add(BucketItem(kind: .text, text: "b"), source: .clipboard)
        manager.add(BucketItem(kind: .text, text: "a"), source: .clipboard) // allowed
        XCTAssertEqual(manager.activeBucket.items.count, 3)
    }

    // MARK: - LRU by count

    func testLRUEvictionByCount() {
        var s = manager.settings
        s.maxItems = 3
        manager.updateSettings(s)

        for i in 0..<5 {
            manager.add(BucketItem(kind: .text, text: "\(i)"), source: .panel)
        }
        // After adding 0, 1, 2, 3, 4 (each inserted at head), items should be [4, 3, 2, 1, 0].
        // Eviction keeps newest 3: [4, 3, 2]
        XCTAssertEqual(manager.activeBucket.items.count, 3)
        XCTAssertEqual(manager.activeBucket.items.map(\.text), ["4", "3", "2"])
    }

    func testLRUSparesPinnedItems() {
        var s = manager.settings
        s.maxItems = 2
        manager.updateSettings(s)

        let oldPinned = BucketItem(kind: .text, text: "old-pinned")
        manager.add(oldPinned, source: .panel)
        manager.togglePin(id: oldPinned.id)

        for i in 0..<5 {
            manager.add(BucketItem(kind: .text, text: "new-\(i)"), source: .panel)
        }

        // Pinned stays, plus newest unpinned up to the cap.
        XCTAssertTrue(manager.activeBucket.items.contains { $0.text == "old-pinned" && $0.pinned })
        XCTAssertEqual(manager.activeBucket.items.count, 2)
    }

    // MARK: - LRU by size

    func testLRUEvictionBySize() {
        var s = manager.settings
        s.maxItems = 1000   // high, so count cap doesn't kick in
        s.maxStorageBytes = 2500
        manager.updateSettings(s)

        func makeFile(_ size: Int64, name: String) -> BucketItem {
            BucketItem(
                kind: .file,
                fileRef: .init(
                    originalPath: "/tmp/\(name)",
                    cachedPath: nil,
                    byteSize: size,
                    uti: "public.data",
                    displayName: name
                )
            )
        }

        manager.add(makeFile(1000, name: "a"), source: .panel)
        manager.add(makeFile(1000, name: "b"), source: .panel)
        manager.add(makeFile(1000, name: "c"), source: .panel) // total 3000 > 2500

        // Oldest ("a") should have been evicted. Items newest-first.
        let names = manager.activeBucket.items.compactMap { $0.fileRef?.displayName }
        XCTAssertFalse(names.contains("a"))
        XCTAssertTrue(names.contains("b"))
        XCTAssertTrue(names.contains("c"))
    }

    // MARK: - Search

    func testSearchMatchesText() {
        manager.add(BucketItem(kind: .text, text: "error log one"), source: .panel)
        manager.add(BucketItem(kind: .text, text: "unrelated"), source: .panel)
        let hits = manager.search("error")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.text, "error log one")
    }

    func testSearchMatchesURLTitle() {
        manager.add(
            BucketItem(kind: .url, urlMeta: .init(urlString: "https://a.test", title: "Swift Docs")),
            source: .panel
        )
        manager.add(
            BucketItem(kind: .url, urlMeta: .init(urlString: "https://b.test", title: "Weather")),
            source: .panel
        )
        let hits = manager.search("swift")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.urlMeta?.title, "Swift Docs")
    }

    func testSearchMatchesFileName() {
        let item = BucketItem(
            kind: .file,
            fileRef: .init(
                originalPath: "/tmp/report.pdf",
                cachedPath: nil,
                byteSize: 100,
                uti: "com.adobe.pdf",
                displayName: "report.pdf"
            )
        )
        manager.add(item, source: .panel)
        XCTAssertEqual(manager.search("report").count, 1)
        XCTAssertEqual(manager.search("pdf").count, 1)
    }

    func testSearchEmptyQueryReturnsAll() {
        manager.add(BucketItem(kind: .text, text: "one"), source: .panel)
        manager.add(BucketItem(kind: .text, text: "two"), source: .panel)
        XCTAssertEqual(manager.search("").count, 2)
        XCTAssertEqual(manager.search("   ").count, 2)
    }

    // MARK: - Persistence

    func testPersistSurvivesReload() async throws {
        let item = BucketItem(kind: .text, text: "persistent")
        manager.add(item, source: .panel)
        await manager.flushForTests()

        // Rebuild manager pointing at the same store.
        let store = BucketStore(rootURL: tempRoot)
        let fresh = BucketManager(store: store)
        fresh.load()
        // load() is fire-and-forget; wait for it.
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(fresh.activeBucket.items.count, 1)
        XCTAssertEqual(fresh.activeBucket.items.first?.text, "persistent")
    }

    // MARK: - Async file + image add (BLOCKER-3 fix)

    func testAddFileAtURLCopiesSidecar() async throws {
        let src = tempRoot.appendingPathComponent("source.txt")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        try "hello".data(using: .utf8)!.write(to: src)

        await manager.add(fileAt: src, source: .panel)

        XCTAssertEqual(manager.activeBucket.items.count, 1)
        let item = manager.activeBucket.items[0]
        XCTAssertEqual(item.kind, .file)
        XCTAssertEqual(item.fileRef?.originalPath, src.path)
        let cached = try XCTUnwrap(item.fileRef?.cachedPath)
        XCTAssertTrue(cached.hasPrefix("files/"))
        let absolute = tempRoot.appendingPathComponent(cached)
        XCTAssertTrue(FileManager.default.fileExists(atPath: absolute.path))
        XCTAssertEqual(try Data(contentsOf: absolute), "hello".data(using: .utf8))
    }

    func testAddImageDataWritesSidecar() async throws {
        await manager.add(imageData: Data([0x89, 0x50, 0x4E, 0x47]), source: .panel)

        XCTAssertEqual(manager.activeBucket.items.count, 1)
        let item = manager.activeBucket.items[0]
        XCTAssertEqual(item.kind, .image)
        let cached = try XCTUnwrap(item.fileRef?.cachedPath)
        XCTAssertTrue(cached.hasPrefix("images/"))
        let absolute = tempRoot.appendingPathComponent(cached)
        XCTAssertTrue(FileManager.default.fileExists(atPath: absolute.path))
    }

    // MARK: - flushPendingWrites (SHOULD-2 fix)

    func testFlushPendingWritesPersistsImmediately() async throws {
        manager.add(BucketItem(kind: .text, text: "not-yet-written"), source: .panel)
        // No flush yet — a fresh manager wouldn't see this because the 500ms
        // debounce hasn't fired.

        await manager.flushPendingWrites()

        let store = BucketStore(rootURL: tempRoot)
        let loaded = try await store.loadBucket()
        XCTAssertEqual(loaded.items.count, 1)
        XCTAssertEqual(loaded.items[0].text, "not-yet-written")
    }
}
