import Foundation

// MARK: - Kinds

enum BucketItemKind: String, Codable, Sendable, CaseIterable {
    case file
    case folder
    case image
    case url
    case text
    case richText
    case color
}

enum ScreenEdge: String, Codable, Sendable, CaseIterable {
    case left
    case right
    case top
    case bottom
}

// MARK: - Item

struct BucketItem: Identifiable, Codable, Sendable, Hashable {
    let id: UUID
    var kind: BucketItemKind
    var createdAt: Date
    var lastAccessedAt: Date
    var pinned: Bool

    /// Real bundle ID (e.g. `com.apple.safari`) OR reserved sentinel
    /// (`net.snor-oh.screenshot`, `net.snor-oh.peer:<uuid>`, etc.) per REVIEW.md §7.
    var sourceBundleID: String?

    /// Items dropped in the same drag session share this ID and render as one card.
    var stackGroupID: UUID?

    /// SHA-256 of the item's canonical bytes. Used for dedupe across clipboard,
    /// screenshot, and peer-received items. Optional because plain text items
    /// often rely on string-equality dedupe instead.
    var contentHash: String?

    // Payload — exactly one non-nil by contract. Not enforced at the type level
    // to keep Codable simple; call sites that insert into BucketManager must
    // respect the invariant.
    var fileRef: FileRef?
    var text: String?
    var urlMeta: URLMetadata?
    var colorHex: String?

    struct FileRef: Codable, Sendable, Hashable {
        var originalPath: String
        /// Relative to the bucket storage directory. Nil until the sidecar copy lands.
        var cachedPath: String?
        var byteSize: Int64
        var uti: String
        var displayName: String
    }

    struct URLMetadata: Codable, Sendable, Hashable {
        var urlString: String
        var title: String?
        /// Relative to the bucket storage directory.
        var faviconPath: String?
        /// Relative to the bucket storage directory.
        var ogImagePath: String?
    }

    init(
        id: UUID = UUID(),
        kind: BucketItemKind,
        createdAt: Date = Date(),
        lastAccessedAt: Date? = nil,
        pinned: Bool = false,
        sourceBundleID: String? = nil,
        stackGroupID: UUID? = nil,
        contentHash: String? = nil,
        fileRef: FileRef? = nil,
        text: String? = nil,
        urlMeta: URLMetadata? = nil,
        colorHex: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.createdAt = createdAt
        self.lastAccessedAt = lastAccessedAt ?? createdAt
        self.pinned = pinned
        self.sourceBundleID = sourceBundleID
        self.stackGroupID = stackGroupID
        self.contentHash = contentHash
        self.fileRef = fileRef
        self.text = text
        self.urlMeta = urlMeta
        self.colorHex = colorHex
    }
}

// MARK: - Bucket

struct Bucket: Identifiable, Codable, Sendable {
    let id: UUID
    var name: String
    var items: [BucketItem]
    var createdAt: Date

    init(
        id: UUID = UUID(),
        name: String = "Default",
        items: [BucketItem] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.items = items
        self.createdAt = createdAt
    }
}

// MARK: - Settings

struct BucketSettings: Codable, Sendable {
    var maxItems: Int
    var maxStorageBytes: Int64
    var captureClipboard: Bool
    var ignoredBundleIDs: Set<String>
    var autoHideSeconds: Double
    var preferredEdge: ScreenEdge
    var hotkey: HotkeyBinding

    init(
        maxItems: Int = 200,
        maxStorageBytes: Int64 = 100_000_000,
        captureClipboard: Bool = true,
        ignoredBundleIDs: Set<String> = [],
        autoHideSeconds: Double = 2.0,
        preferredEdge: ScreenEdge = .right,
        hotkey: HotkeyBinding = HotkeyBinding(key: "B", modifiers: [.control, .option])
    ) {
        self.maxItems = maxItems
        self.maxStorageBytes = maxStorageBytes
        self.captureClipboard = captureClipboard
        self.ignoredBundleIDs = ignoredBundleIDs
        self.autoHideSeconds = autoHideSeconds
        self.preferredEdge = preferredEdge
        self.hotkey = hotkey
    }

    /// Forward-compatible decoding: any future field added here MUST have a default
    /// so older on-disk JSON can still decode via this init.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.maxItems = try c.decodeIfPresent(Int.self, forKey: .maxItems) ?? 200
        self.maxStorageBytes = try c.decodeIfPresent(Int64.self, forKey: .maxStorageBytes) ?? 100_000_000
        self.captureClipboard = try c.decodeIfPresent(Bool.self, forKey: .captureClipboard) ?? true
        self.ignoredBundleIDs = try c.decodeIfPresent(Set<String>.self, forKey: .ignoredBundleIDs) ?? []
        self.autoHideSeconds = try c.decodeIfPresent(Double.self, forKey: .autoHideSeconds) ?? 2.0
        self.preferredEdge = try c.decodeIfPresent(ScreenEdge.self, forKey: .preferredEdge) ?? .right
        self.hotkey = try c.decodeIfPresent(HotkeyBinding.self, forKey: .hotkey)
            ?? HotkeyBinding(key: "B", modifiers: [.control, .option])
    }
}

// MARK: - Hotkey binding

struct HotkeyBinding: Codable, Sendable, Hashable {
    var key: String
    var modifiers: Set<Modifier>

    enum Modifier: String, Codable, Sendable, Hashable, CaseIterable {
        case command
        case option
        case control
        case shift
    }
}

// MARK: - Bucket notification `source` sentinels

/// Values for `.bucketChanged` `userInfo["source"]`. Kept as `String` on the
/// notification itself for JSON-friendliness; this enum is the canonical
/// writer side. Consumers (Epic 02 catch reaction, telemetry) compare as strings.
enum BucketChangeSource: String, Sendable {
    case panel
    case mascot
    case clipboard
    case screenshot
    case peer
    case watchedFolder = "watched-folder"
    case shortcut
    case urlScheme = "url-scheme"
}

/// Values for `.bucketChanged` `userInfo["change"]`.
enum BucketChangeKind: String, Sendable {
    case added
    case removed
    case pinned
    case unpinned
    case cleared
}
