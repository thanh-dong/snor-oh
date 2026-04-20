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
    var colorHex: String
    var emoji: String?
    var archived: Bool
    var keyboardIndex: Int?

    init(
        id: UUID = UUID(),
        name: String = "Default",
        items: [BucketItem] = [],
        createdAt: Date = Date(),
        colorHex: String = "#FF9500",
        emoji: String? = nil,
        archived: Bool = false,
        keyboardIndex: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.items = items
        self.createdAt = createdAt
        self.colorHex = colorHex
        self.emoji = emoji
        self.archived = archived
        self.keyboardIndex = keyboardIndex
    }

    /// Forward-compatible decoding: Epic 01 persisted Buckets without
    /// colorHex/emoji/archived/keyboardIndex. Older JSON still decodes with defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.items = try c.decodeIfPresent([BucketItem].self, forKey: .items) ?? []
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        self.colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex) ?? "#FF9500"
        self.emoji = try c.decodeIfPresent(String.self, forKey: .emoji)
        self.archived = try c.decodeIfPresent(Bool.self, forKey: .archived) ?? false
        self.keyboardIndex = try c.decodeIfPresent(Int.self, forKey: .keyboardIndex)
    }
}

// MARK: - Auto-route rules

enum RouteCondition: Codable, Sendable, Hashable {
    case frontmostApp(bundleID: String)
    case itemKind(BucketItemKind)
    case sourceApp(bundleID: String)
    case urlHost(String)
}

struct AutoRouteRule: Codable, Sendable, Hashable, Identifiable {
    let id: UUID
    var bucketID: UUID
    var condition: RouteCondition
    var enabled: Bool

    init(id: UUID = UUID(), bucketID: UUID, condition: RouteCondition, enabled: Bool = true) {
        self.id = id
        self.bucketID = bucketID
        self.condition = condition
        self.enabled = enabled
    }
}

// MARK: - Palette

enum BucketPalette {
    static let swatches: [String] = [
        "#FF3B30", "#FF9500", "#FFCC00", "#34C759",
        "#007AFF", "#AF52DE", "#8E8E93", "#A2845E",
    ]
}

// MARK: - Manifest envelope (v2)

struct BucketManifestV2: Codable, Sendable {
    var schemaVersion: Int
    var activeBucketID: UUID
    var buckets: [Bucket]
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
    var quickPasteHotkey: HotkeyBinding
    var quickPasteCount: Int
    var autoRouteRules: [AutoRouteRule]
    /// Window alpha for the Bucket panel (0.10…1.0). Wired to
    /// `NSPanel.alphaValue`, so 0.10 makes the whole bucket (including the
    /// VisualEffect blur) ghostly see-through and 1.0 is fully solid.
    /// Floor of 0.10 is enforced by the settings slider — never store a
    /// smaller value or the window becomes unclickable.
    var backgroundOpacity: Double

    init(
        maxItems: Int = 200,
        maxStorageBytes: Int64 = 100_000_000,
        captureClipboard: Bool = true,
        ignoredBundleIDs: Set<String> = [],
        autoHideSeconds: Double = 2.0,
        preferredEdge: ScreenEdge = .right,
        hotkey: HotkeyBinding = HotkeyBinding(key: "B", modifiers: [.command, .shift]),
        quickPasteHotkey: HotkeyBinding = HotkeyBinding(key: "V", modifiers: [.command, .shift]),
        quickPasteCount: Int = 5,
        autoRouteRules: [AutoRouteRule] = [],
        backgroundOpacity: Double = 0.10
    ) {
        self.maxItems = maxItems
        self.maxStorageBytes = maxStorageBytes
        self.captureClipboard = captureClipboard
        self.ignoredBundleIDs = ignoredBundleIDs
        self.autoHideSeconds = autoHideSeconds
        self.preferredEdge = preferredEdge
        self.hotkey = hotkey
        self.quickPasteHotkey = quickPasteHotkey
        self.quickPasteCount = quickPasteCount
        self.autoRouteRules = autoRouteRules
        self.backgroundOpacity = backgroundOpacity
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
        // Default bucket-toggle hotkey changed to ⌘⇧B in v0.6.0; users who had
        // the old ⌃⌥B in their manifest keep it, fresh installs get the new one.
        self.hotkey = try c.decodeIfPresent(HotkeyBinding.self, forKey: .hotkey)
            ?? HotkeyBinding(key: "B", modifiers: [.command, .shift])
        self.quickPasteHotkey = try c.decodeIfPresent(HotkeyBinding.self, forKey: .quickPasteHotkey)
            ?? HotkeyBinding(key: "V", modifiers: [.command, .shift])
        self.quickPasteCount = try c.decodeIfPresent(Int.self, forKey: .quickPasteCount) ?? 5
        self.autoRouteRules = try c.decodeIfPresent([AutoRouteRule].self, forKey: .autoRouteRules) ?? []
        self.backgroundOpacity = try c.decodeIfPresent(Double.self, forKey: .backgroundOpacity) ?? 0.10
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

// MARK: - Defaults

/// Bundle IDs auto-added to `BucketSettings.ignoredBundleIDs` on first run.
///
/// Terminals routinely put selected text on the pasteboard (via the app's
/// "Copy on selection" setting or app-initiated writes), which would fill
/// the bucket with command-line noise. Password managers put secrets on
/// the pasteboard on purpose — those must never be captured.
///
/// Users can remove entries via Settings → Bucket → Ignored apps if they
/// specifically want to capture from one of these apps (e.g. explicit ⌘C
/// from Terminal).
enum BucketDefaults {
    static let ignoredBundleIDs: Set<String> = [
        // Terminals
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "net.kovidgoyal.kitty",
        "org.alacritty",
        "com.github.wez.wezterm",
        "dev.warp.Warp-Stable",
        "co.zeit.hyper",
        "org.tabby",

        // Password managers
        "com.agilebits.onepassword7",
        "com.1password.1password",
        "com.1password.1password8",
        "com.bitwarden.desktop",
        "com.lastpass.LastPass",
        "org.keepassxc.keepassxc",
    ]
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
    case activeBucketChanged = "active-bucket-changed"
    case bucketCreated = "bucket-created"
    case bucketUpdated = "bucket-updated"
    case bucketArchived = "bucket-archived"
    case bucketRestored = "bucket-restored"
    case bucketDeleted = "bucket-deleted"
}
