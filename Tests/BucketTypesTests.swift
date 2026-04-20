import XCTest
@testable import SnorOhSwift

final class BucketTypesTests: XCTestCase {

    // MARK: - BucketItem round-trip per kind

    func testCodableRoundTripFile() throws {
        let item = BucketItem(
            kind: .file,
            sourceBundleID: "com.apple.finder",
            fileRef: .init(
                originalPath: "/tmp/foo.txt",
                cachedPath: "files/abc.txt",
                byteSize: 1024,
                uti: "public.plain-text",
                displayName: "foo.txt"
            )
        )
        try assertCodableRoundTrip(item)
    }

    func testCodableRoundTripText() throws {
        let item = BucketItem(kind: .text, text: "hello world")
        try assertCodableRoundTrip(item)
    }

    func testCodableRoundTripRichText() throws {
        let item = BucketItem(kind: .richText, text: "base64-rtf-here")
        try assertCodableRoundTrip(item)
    }

    func testCodableRoundTripURL() throws {
        let item = BucketItem(
            kind: .url,
            urlMeta: .init(
                urlString: "https://example.com",
                title: "Example",
                faviconPath: "favicons/ab.ico",
                ogImagePath: "og/cd.jpg"
            )
        )
        try assertCodableRoundTrip(item)
    }

    func testCodableRoundTripImage() throws {
        let item = BucketItem(
            kind: .image,
            fileRef: .init(
                originalPath: "/tmp/shot.png",
                cachedPath: "images/xx.png",
                byteSize: 42_000,
                uti: "public.png",
                displayName: "shot.png"
            )
        )
        try assertCodableRoundTrip(item)
    }

    func testCodableRoundTripColor() throws {
        let item = BucketItem(kind: .color, colorHex: "#FF9500")
        try assertCodableRoundTrip(item)
    }

    func testCodableRoundTripFolder() throws {
        let item = BucketItem(
            kind: .folder,
            fileRef: .init(
                originalPath: "/tmp/project",
                cachedPath: nil,
                byteSize: 0,
                uti: "public.folder",
                displayName: "project"
            )
        )
        try assertCodableRoundTrip(item)
    }

    // MARK: - Bucket round-trip

    func testBucketRoundTrip() throws {
        let bucket = Bucket(
            name: "Default",
            items: [
                BucketItem(kind: .text, text: "hello"),
                BucketItem(kind: .url, urlMeta: .init(urlString: "https://a.test", title: nil)),
            ]
        )
        let data = try JSONEncoder().encode(bucket)
        let decoded = try JSONDecoder().decode(Bucket.self, from: data)
        XCTAssertEqual(decoded.id, bucket.id)
        XCTAssertEqual(decoded.name, bucket.name)
        XCTAssertEqual(decoded.items, bucket.items)
    }

    // MARK: - Settings forward-compat

    func testSettingsDecodesWithMissingFields() throws {
        // Older on-disk JSON with no fields at all still decodes with defaults.
        let minimal = Data("{}".utf8)
        let decoded = try JSONDecoder().decode(BucketSettings.self, from: minimal)
        XCTAssertEqual(decoded.maxItems, 200)
        XCTAssertEqual(decoded.maxStorageBytes, 100_000_000)
        XCTAssertTrue(decoded.captureClipboard)
        XCTAssertTrue(decoded.ignoredBundleIDs.isEmpty)
        XCTAssertEqual(decoded.autoHideSeconds, 2.0)
        XCTAssertEqual(decoded.preferredEdge, .right)
        XCTAssertEqual(decoded.hotkey.key, "B")
        // Default bucket-toggle changed to ⌘⇧B in v0.6.0.
        XCTAssertEqual(decoded.hotkey.modifiers, [.command, .shift])
        // Quick-paste defaults (Task C).
        XCTAssertEqual(decoded.quickPasteHotkey.key, "V")
        XCTAssertEqual(decoded.quickPasteHotkey.modifiers, [.command, .shift])
        XCTAssertEqual(decoded.quickPasteCount, 5)
    }

    func testSettingsRoundTrip() throws {
        let s = BucketSettings(
            maxItems: 50,
            maxStorageBytes: 1_000_000,
            captureClipboard: false,
            ignoredBundleIDs: ["com.1password.1password"],
            autoHideSeconds: 5,
            preferredEdge: .left,
            hotkey: HotkeyBinding(key: "K", modifiers: [.command, .shift])
        )
        let data = try JSONEncoder().encode(s)
        let decoded = try JSONDecoder().decode(BucketSettings.self, from: data)
        XCTAssertEqual(decoded.maxItems, s.maxItems)
        XCTAssertEqual(decoded.maxStorageBytes, s.maxStorageBytes)
        XCTAssertEqual(decoded.captureClipboard, s.captureClipboard)
        XCTAssertEqual(decoded.ignoredBundleIDs, s.ignoredBundleIDs)
        XCTAssertEqual(decoded.autoHideSeconds, s.autoHideSeconds)
        XCTAssertEqual(decoded.preferredEdge, s.preferredEdge)
        XCTAssertEqual(decoded.hotkey, s.hotkey)
    }

    // MARK: - HotkeyBinding modifier set order-independence

    func testHotkeyBindingSetOrderIndependence() {
        let a = HotkeyBinding(key: "B", modifiers: [.control, .option])
        let b = HotkeyBinding(key: "B", modifiers: [.option, .control])
        XCTAssertEqual(a, b)
    }

    // MARK: - Default item timestamps

    func testBucketItemDefaultsLastAccessedToCreatedAt() {
        let now = Date()
        let item = BucketItem(kind: .text, createdAt: now, text: "x")
        XCTAssertEqual(item.lastAccessedAt, now)
    }

    // MARK: - Helpers

    private func assertCodableRoundTrip<T: Codable & Equatable>(_ value: T) throws {
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(T.self, from: data)
        XCTAssertEqual(decoded, value)
    }
}
