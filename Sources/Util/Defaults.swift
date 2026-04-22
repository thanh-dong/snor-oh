import Foundation

/// UserDefaults keys for persistent settings.
enum DefaultsKey {
    static let theme = "theme"
    static let pet = "pet"
    static let nickname = "nickname"
    static let displayScale = "displayScale"
    static let mascotVisible = "mascotVisible"
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
    /// One-time migration marker: have we seeded default terminal + password
    /// manager bundle IDs into the ignore list?
    static let bucketIgnoreDefaultsSeeded = "bucketIgnoreDefaultsSeeded"
    /// Background-tint solidity for the Bucket window (0.10…1.0). Mirrors
    /// `BucketSettings.backgroundOpacity` for documentation.
    static let bucketBackgroundOpacity = "bucketBackgroundOpacity"
    /// Epic 07 follow-up — user's preferred expanded height, remembered
    /// across auto-collapse / auto-expand cycles. Separate from
    /// `bucketWindowHeight` (which tracks the *current* frame height, and
    /// temporarily drops to the collapsed value while hidden).
    static let bucketExpandedHeight = "bucketExpandedHeight"
}

enum DefaultsDefault {
    static let marketplaceURL = "https://snor-oh.vercel.app"
}
