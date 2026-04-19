import XCTest
@testable import SnorOhSwift

final class BucketStoreTests: XCTestCase {

    var tempRoot: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("bucket-store-test-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempRoot)
        try await super.tearDown()
    }

    // MARK: - Manifest round-trip

    func testLoadReturnsEmptyBucketWhenMissing() async throws {
        let store = BucketStore(rootURL: tempRoot)
        let bucket = try await store.loadBucket()
        XCTAssertTrue(bucket.items.isEmpty)
        XCTAssertEqual(bucket.name, "Default")
    }

    func testSaveAndLoadRoundTrip() async throws {
        let store = BucketStore(rootURL: tempRoot)
        let original = Bucket(
            name: "Work",
            items: [
                BucketItem(kind: .text, text: "hello"),
                BucketItem(kind: .url, urlMeta: .init(urlString: "https://x.test", title: "X")),
            ]
        )
        try await store.saveBucket(original)
        let loaded = try await store.loadBucket()
        XCTAssertEqual(loaded.id, original.id)
        XCTAssertEqual(loaded.name, "Work")
        XCTAssertEqual(loaded.items.count, 2)
        XCTAssertEqual(loaded.items[0].text, "hello")
        XCTAssertEqual(loaded.items[1].urlMeta?.urlString, "https://x.test")
    }

    // MARK: - Settings round-trip

    func testSettingsDefaultWhenMissing() async throws {
        let store = BucketStore(rootURL: tempRoot)
        let s = try await store.loadSettings()
        XCTAssertEqual(s.maxItems, 200)
    }

    func testSettingsRoundTrip() async throws {
        let store = BucketStore(rootURL: tempRoot)
        var s = BucketSettings()
        s.captureClipboard = false
        s.ignoredBundleIDs = ["com.example.app"]
        try await store.saveSettings(s)
        let loaded = try await store.loadSettings()
        XCTAssertFalse(loaded.captureClipboard)
        XCTAssertEqual(loaded.ignoredBundleIDs, ["com.example.app"])
    }

    // MARK: - Sidecar copy

    func testCopySidecarFromFile() async throws {
        let store = BucketStore(rootURL: tempRoot)
        let src = tempRoot.appendingPathComponent("source.txt")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        try "hello".data(using: .utf8)!.write(to: src)

        let itemID = UUID()
        let rel = try await store.copySidecar(from: src, itemID: itemID, subdir: "files")

        XCTAssertTrue(rel.hasPrefix("files/"))
        XCTAssertTrue(rel.hasSuffix("\(itemID.uuidString).txt"))

        let absolute = store.absoluteURL(forRelative: rel)
        XCTAssertTrue(FileManager.default.fileExists(atPath: absolute.path))
        XCTAssertEqual(try Data(contentsOf: absolute), "hello".data(using: .utf8))

        // Copy (not move) — source still exists
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.path))
    }

    func testMoveSidecar() async throws {
        let store = BucketStore(rootURL: tempRoot)
        let src = tempRoot.appendingPathComponent("source.png")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        try Data([0xDE, 0xAD, 0xBE, 0xEF]).write(to: src)

        let rel = try await store.copySidecar(from: src, itemID: UUID(), subdir: "images", move: true)

        XCTAssertTrue(rel.hasPrefix("images/"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: src.path),
                       "Source should be removed after move")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.absoluteURL(forRelative: rel).path))
    }

    func testWriteSidecarRawBytes() async throws {
        let store = BucketStore(rootURL: tempRoot)
        let rel = try await store.writeSidecar(
            Data([1, 2, 3, 4]),
            itemID: UUID(),
            subdir: "images",
            ext: "png"
        )
        let absolute = store.absoluteURL(forRelative: rel)
        XCTAssertTrue(FileManager.default.fileExists(atPath: absolute.path))
        XCTAssertEqual(try Data(contentsOf: absolute), Data([1, 2, 3, 4]))
    }

    // MARK: - Delete sidecars

    func testDeleteSidecarsRemovesFiles() async throws {
        let store = BucketStore(rootURL: tempRoot)
        let src = tempRoot.appendingPathComponent("src.txt")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        try "x".data(using: .utf8)!.write(to: src)

        let rel1 = try await store.copySidecar(from: src, itemID: UUID(), subdir: "files")
        let rel2 = try await store.copySidecar(from: src, itemID: UUID(), subdir: "files")

        await store.deleteSidecars(relativePaths: [rel1, rel2])

        XCTAssertFalse(FileManager.default.fileExists(atPath: store.absoluteURL(forRelative: rel1).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.absoluteURL(forRelative: rel2).path))
    }

    func testDeleteSidecarsIgnoresMissing() async throws {
        let store = BucketStore(rootURL: tempRoot)
        // Should not throw
        await store.deleteSidecars(relativePaths: ["files/nonexistent.txt"])
    }

    // MARK: - Storage size

    func testSidecarStorageBytesSumsAcrossSubdirs() async throws {
        let store = BucketStore(rootURL: tempRoot)
        _ = try await store.writeSidecar(Data(count: 1000), itemID: UUID(), subdir: "files", ext: "bin")
        _ = try await store.writeSidecar(Data(count: 2000), itemID: UUID(), subdir: "images", ext: "png")
        _ = try await store.writeSidecar(Data(count: 500), itemID: UUID(), subdir: "favicons", ext: "ico")

        let total = await store.sidecarStorageBytes()
        XCTAssertEqual(total, 3500)
    }

    // MARK: - Atomic write

    func testAtomicWriteOverwritesExisting() async throws {
        let store = BucketStore(rootURL: tempRoot)
        let b1 = Bucket(name: "First", items: [])
        try await store.saveBucket(b1)

        let b2 = Bucket(name: "Second", items: [BucketItem(kind: .text, text: "x")])
        try await store.saveBucket(b2)

        let loaded = try await store.loadBucket()
        XCTAssertEqual(loaded.name, "Second")
        XCTAssertEqual(loaded.items.count, 1)
    }
}
