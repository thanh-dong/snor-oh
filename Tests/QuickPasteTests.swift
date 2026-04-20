import XCTest
import AppKit
@testable import SnorOhSwift

@MainActor
final class QuickPasteTests: XCTestCase {

    var tempRoot: URL!
    var manager: BucketManager!

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("quickpaste-test-\(UUID().uuidString)")
        let store = BucketStore(rootURL: tempRoot)
        manager = BucketManager(store: store)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempRoot)
        try await super.tearDown()
    }

    // MARK: - latestItemsAcrossActiveBuckets

    func testLatestReturnsNewestFirstAcrossBuckets() {
        let a = manager.buckets[0].id
        let b = manager.createBucket(name: "B")

        // Seed three items with explicit lastAccessedAt timestamps, spread
        // across two buckets. Must come out newest-first regardless of bucket.
        let old = BucketItem(kind: .text, createdAt: Date(timeIntervalSince1970: 100), text: "old")
        let mid = BucketItem(kind: .text, createdAt: Date(timeIntervalSince1970: 200), text: "mid")
        let new = BucketItem(kind: .text, createdAt: Date(timeIntervalSince1970: 300), text: "new")

        manager.add(old, source: .panel, toBucket: a)
        manager.add(mid, source: .panel, toBucket: b)
        manager.add(new, source: .panel, toBucket: a)

        let result = manager.latestItemsAcrossActiveBuckets(limit: 5)
        XCTAssertEqual(result.map(\.text), ["new", "mid", "old"],
                       "should be ordered newest-first by lastAccessedAt")
    }

    func testLatestSkipsArchivedBuckets() {
        let a = manager.buckets[0].id
        let shelf = manager.createBucket(name: "Shelf")
        manager.add(BucketItem(kind: .text, text: "alive"), source: .panel, toBucket: a)
        manager.add(BucketItem(kind: .text, text: "shelved"), source: .panel, toBucket: shelf)
        manager.archiveBucket(id: shelf)

        let result = manager.latestItemsAcrossActiveBuckets(limit: 5)
        XCTAssertEqual(result.map(\.text), ["alive"],
                       "archived buckets must not appear in quick-paste")
    }

    func testLatestHonorsLimit() {
        let a = manager.buckets[0].id
        for i in 0..<10 {
            manager.add(BucketItem(kind: .text, text: "n\(i)"), source: .panel, toBucket: a)
        }
        XCTAssertEqual(manager.latestItemsAcrossActiveBuckets(limit: 3).count, 3)
        XCTAssertEqual(manager.latestItemsAcrossActiveBuckets(limit: 0).count, 0)
    }

    // MARK: - QuickPaster pasteboard

    func testPasteTextWritesPlainString() {
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = BucketItem(kind: .text, text: "hello world")
        QuickPaster.copyItemToPasteboard(item, sidecarRoot: tempRoot)
        XCTAssertEqual(pb.string(forType: .string), "hello world")
    }

    func testPasteURLWritesString() {
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = BucketItem(
            kind: .url,
            urlMeta: .init(urlString: "https://example.com", title: nil)
        )
        QuickPaster.copyItemToPasteboard(item, sidecarRoot: tempRoot)
        XCTAssertEqual(pb.string(forType: .string), "https://example.com")
    }

    func testPasteColorWritesHexAsString() {
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = BucketItem(kind: .color, colorHex: "#FF5733")
        QuickPaster.copyItemToPasteboard(item, sidecarRoot: tempRoot)
        XCTAssertEqual(pb.string(forType: .string), "#FF5733")
    }

    func testPasteFileFallsBackToPathStringIfMissing() {
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = BucketItem(
            kind: .file,
            fileRef: .init(
                originalPath: "/nonexistent/file.txt",
                cachedPath: nil,
                byteSize: 0,
                uti: "public.text",
                displayName: "file.txt"
            )
        )
        QuickPaster.copyItemToPasteboard(item, sidecarRoot: tempRoot)
        // File doesn't exist → we fall back to pasting the path as text.
        XCTAssertEqual(pb.string(forType: .string), "/nonexistent/file.txt")
    }

    // MARK: - HotkeyFormatter

    func testDescribeCmdShiftB() {
        let b = HotkeyBinding(key: "B", modifiers: [.command, .shift])
        XCTAssertEqual(HotkeyFormatter.describe(b), "⇧⌘B")
    }

    func testDescribeAppleModifierOrder() {
        // Apple's canonical order: ⌃⌥⇧⌘<key>
        let b = HotkeyBinding(key: "K", modifiers: [.command, .option, .control, .shift])
        XCTAssertEqual(HotkeyFormatter.describe(b), "⌃⌥⇧⌘K")
    }
}
