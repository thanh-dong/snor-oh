import Foundation
import os.log

/// OSLog wrapper for structured logging.
enum Log {
    private static let subsystem = "com.snoroh.swift"

    static let app = os.Logger(subsystem: subsystem, category: "app")
    static let http = os.Logger(subsystem: subsystem, category: "http")
    static let session = os.Logger(subsystem: subsystem, category: "session")
    static let network = os.Logger(subsystem: subsystem, category: "network")
    static let setup = os.Logger(subsystem: subsystem, category: "setup")
    /// Auto-collapse diagnostic trail — becomeKey / resignKey / applyCollapseState
    /// and companion init validations. Filter by category `"bucket-collapse"`
    /// in Console.app to read just the collapse story.
    static let bucketCollapse = os.Logger(subsystem: subsystem, category: "bucket-collapse")
}
