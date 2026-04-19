import Foundation

/// UserDefaults keys for persistent settings.
enum DefaultsKey {
    static let theme = "theme"
    static let pet = "pet"
    static let nickname = "nickname"
    static let displayScale = "displayScale"
    static let glowMode = "glowMode"
    static let bubbleEnabled = "bubbleEnabled"
    static let hideDock = "hideDock"
    static let trayVisible = "trayVisible"
    static let sidebarCollapsed = "sidebarCollapsed"
    static let panelSize = "panelSize"
    static let panelPositionX = "panelPositionX"
    static let panelPositionY = "panelPositionY"
    static let mascotPositionX = "mascotPositionX"
    static let mascotPositionY = "mascotPositionY"
    static let peerDiscoveryEnabled = "peerDiscoveryEnabled"
    static let devMode = "devMode"
    static let marketplaceURL = "marketplaceURL"
    static let creatorName = "creatorName"

    // MARK: - Bucket feature (Epic 01)
    /// Whether clipboard capture is running. Mirrors `BucketSettings.captureClipboard`
    /// for quick @AppStorage access from UI toggles.
    static let bucketCaptureClipboard = "bucketCaptureClipboard"
    /// Max items in the bucket (LRU eviction at this count).
    static let bucketMaxItems = "bucketMaxItems"
    /// Max total sidecar storage in MB (LRU eviction by size).
    static let bucketMaxStorageMB = "bucketMaxStorageMB"
    /// JSON-encoded `[String]` of ignored bundle IDs.
    static let bucketIgnoredBundleIDs = "bucketIgnoredBundleIDs"
    /// JSON-encoded `HotkeyBinding`.
    static let bucketHotkey = "bucketHotkey"
    /// One-time first-launch bubble gate.
    static let bucketTipShown = "bucketTipShown"
    /// Standalone `BucketWindow` position + size (replaces obsolete
    /// `bucketActiveTab` — the bucket is no longer an in-panel tab).
    static let bucketWindowX = "bucketWindowX"
    static let bucketWindowY = "bucketWindowY"
    static let bucketWindowWidth = "bucketWindowWidth"
    static let bucketWindowHeight = "bucketWindowHeight"
}

enum DefaultsDefault {
    static let marketplaceURL = "https://snor-oh.vercel.app"
}
