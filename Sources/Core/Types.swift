import Foundation
import Network

// MARK: - Status

enum Status: String, CaseIterable, Sendable {
    case initializing
    case searching
    case idle
    case busy
    case service
    case disconnected
    case visiting
    case carrying

    /// Priority for UI resolution: higher wins.
    ///
    /// `.carrying` lives between `.idle` and `.service` so it only surfaces
    /// when no Claude Code / terminal activity is demanding the sprite. Epic 02.
    var priority: Int {
        switch self {
        case .busy: return 5
        case .service: return 4
        case .carrying: return 3
        case .idle: return 2
        case .visiting: return 1
        case .disconnected, .searching, .initializing: return 0
        }
    }

    var displayLabel: String {
        switch self {
        case .initializing: return "Starting"
        case .searching: return "Searching"
        case .idle: return "Free"
        case .busy: return "Working"
        case .service: return "Service"
        case .disconnected: return "Sleep"
        case .visiting: return "Visiting"
        case .carrying: return "Carrying"
        }
    }

    var dotColor: String {
        switch self {
        case .idle: return "green"
        case .busy: return "red"
        case .service: return "blue"
        case .searching, .initializing: return "yellow"
        case .disconnected: return "gray"
        case .visiting: return "teal"
        case .carrying: return "orange"
        }
    }

    // MARK: - Sprite scope

    /// Statuses that *must* have a dedicated sprite sheet in every pet's asset
    /// catalog. This is the iteration surface used by import/export, Smart
    /// Import, and per-pet sprite writers — `Status.allCases` itself stays
    /// exhaustive (new cases like `.carrying` opt out of requiring art).
    ///
    /// Why exclude `.carrying`: it's a runtime-only display promotion (see
    /// `resolveDisplay`). Legacy `.snoroh` files and `custom-ohhs.json` on
    /// disk predate it and don't carry a sprite entry for it — forcing one
    /// would break every existing import and every existing custom ohh.
    /// `SpriteConfig.sheet(pet:status:)` falls back to the idle sheet when a
    /// pet lacks a carrying asset, so requiring the key here is unnecessary.
    static let spriteStatuses: [Status] = [
        .initializing, .searching, .idle, .busy, .service, .disconnected, .visiting,
    ]

    // MARK: - Epic 02 display resolver

    /// Resolves the status the mascot should *show* for a given session-derived
    /// status and current bucket item count. Pure function — no side effects.
    ///
    /// Rules:
    /// - If the bucket is empty, show the session status unchanged.
    /// - Otherwise, if the session status is "quiet" (idle/disconnected/searching/initializing/visiting),
    ///   promote the display to `.carrying`.
    /// - Never override `.busy` or `.service` — Claude Code activity always wins.
    static func resolveDisplay(sessionStatus: Status, bucketCount: Int) -> Status {
        guard bucketCount > 0 else { return sessionStatus }
        switch sessionStatus {
        case .busy, .service:
            return sessionStatus
        case .idle, .disconnected, .searching, .initializing, .visiting, .carrying:
            return .carrying
        }
    }
}

// MARK: - Session

struct Session {
    var busyType: String = ""        // "task", "service", or "" (idle)
    var uiState: Status = .idle
    var lastSeen: UInt64 = 0         // Unix timestamp
    var serviceSince: UInt64 = 0     // When service state started (0 = not in service)
    var busySince: UInt64 = 0        // When busy state started (0 = not busy)
    var cwd: String? = nil           // Working directory for project identification

    /// `ps -o lstart=` string captured at session-start, used to detect macOS
    /// PID reuse. `nil` for legacy sessions created via `/heartbeat` before
    /// `/session-start` existed — those fall back to plain `kill(0)` checks.
    var startedAt: String? = nil

    /// "shell" or "claude". Source of the session registration — lets the UI
    /// eventually distinguish "terminal open" from "claude running". Optional
    /// so legacy heartbeat-only sessions don't require a reshuffle.
    var kind: String? = nil
}

// MARK: - Peer / Visitor

struct PeerInfo: Identifiable {
    var id: String { instanceName }
    let instanceName: String
    let nickname: String
    let pet: String
    let host: String   // IP address or fallback
    let port: UInt16
    let ip: String?    // resolved IPv4 from TXT
    let endpoint: NWEndpoint?  // Bonjour endpoint for on-demand IP resolution
}

struct VisitingDog: Identifiable, Sendable {
    var id: String { instanceName }
    let instanceName: String
    let pet: String
    let nickname: String
    let arrivedAt: UInt64
    let durationSecs: UInt64
}

// MARK: - Project (Multi-Session)

struct ProjectStatus: Identifiable {
    var id: String { path }
    let path: String             // Full CWD path (unique key)
    let name: String             // Last path component
    let status: Status           // Aggregate: busy > service > idle
    let sessions: [UInt32]       // Contributing PIDs
    let activeSince: Date        // When current status started
    var modifiedFiles: Int = 0   // From git status (polled)
}

// MARK: - Usage

struct UsageToday {
    var tasksCompleted: Int = 0
    var totalBusySecs: UInt64 = 0
    var longestTaskSecs: UInt64 = 0
    var lastTaskDurationSecs: UInt64 = 0
    var usageDay: UInt64 = 0     // Days since epoch, for daily reset
}

// MARK: - MCP Payloads

struct MCPSayPayload: Codable {
    let message: String
    var durationSecs: UInt64? = nil

    enum CodingKeys: String, CodingKey {
        case message
        case durationSecs = "duration_secs"
    }
}

struct MCPReactPayload: Codable {
    let reaction: String
    var durationSecs: UInt64? = nil

    enum CodingKeys: String, CodingKey {
        case reaction
        case durationSecs = "duration_secs"
    }
}

struct PeerMessagePayload: Codable {
    let sender: String
    let message: String
}

struct VisitPayload: Codable {
    let instanceName: String
    let pet: String
    let nickname: String
    var durationSecs: UInt64? = nil

    enum CodingKeys: String, CodingKey {
        case instanceName = "instance_name"
        case pet
        case nickname
        case durationSecs = "duration_secs"
    }
}

struct VisitEndPayload: Codable {
    var instanceName: String? = nil
    var nickname: String? = nil

    enum CodingKeys: String, CodingKey {
        case instanceName = "instance_name"
        case nickname
    }
}

// MARK: - Session Lifecycle Payloads

struct SessionStartPayload: Codable {
    let pid: UInt32
    let cwd: String
    let kind: String          // "shell" | "claude"
    let startedAt: String?    // `ps -o lstart=` string; optional for resilience

    enum CodingKeys: String, CodingKey {
        case pid
        case cwd
        case kind
        case startedAt = "started_at"
    }
}

struct SessionEndPayload: Codable {
    let pid: UInt32
}

// MARK: - Pet Status (MCP Response)

struct PetStatusResponse: Codable {
    let petType: String
    let nickname: String
    let currentStatus: String
    let sleeping: Bool
    let sessionsActive: Int
    let peersNearby: Int
    let visitors: [VisitorInfo]
    let isVisiting: Bool
    let uptimeSecs: UInt64
    let currentBusySecs: UInt64
    let usageToday: UsageTodayResponse
    let projects: [ProjectInfo]

    enum CodingKeys: String, CodingKey {
        case petType = "pet_type"
        case nickname
        case currentStatus = "current_status"
        case sleeping
        case sessionsActive = "sessions_active"
        case peersNearby = "peers_nearby"
        case visitors
        case isVisiting = "is_visiting"
        case uptimeSecs = "uptime_secs"
        case currentBusySecs = "current_busy_secs"
        case usageToday = "usage_today"
        case projects
    }
}

struct VisitorInfo: Codable {
    let nickname: String
    let pet: String
}

struct UsageTodayResponse: Codable {
    let tasksCompleted: Int
    let totalBusyMins: UInt64
    let longestTaskMins: UInt64
    let lastTaskDurationSecs: UInt64

    enum CodingKeys: String, CodingKey {
        case tasksCompleted = "tasks_completed"
        case totalBusyMins = "total_busy_mins"
        case longestTaskMins = "longest_task_mins"
        case lastTaskDurationSecs = "last_task_duration_secs"
    }
}

struct ProjectInfo: Codable {
    let name: String
    let status: String
    let modifiedFiles: Int
    let sessions: Int

    enum CodingKeys: String, CodingKey {
        case name
        case status
        case modifiedFiles = "modified_files"
        case sessions
    }
}

// MARK: - Custom Ohh

struct CustomOhhData: Codable, Identifiable {
    let id: String
    var name: String
    var sprites: [String: SpriteEntry]  // Status.rawValue → SpriteEntry

    /// Present only for ohhs created via Smart Import; enables re-editing.
    var smartImportMeta: SmartImportMeta?

    struct SpriteEntry: Codable {
        let fileName: String
        let frames: Int
    }

    struct SmartImportMeta: Codable {
        let sheetFileName: String
        let frameInputs: [String: String]  // Status.rawValue → frame input string (e.g. "1-5")
    }

    /// Lookup sprite entry for a given status.
    func sprite(for status: Status) -> SpriteEntry? {
        sprites[status.rawValue]
    }
}

// MARK: - Helpers

func nowSecs() -> UInt64 {
    UInt64(Date().timeIntervalSince1970)
}

func currentDay() -> UInt64 {
    nowSecs() / 86400
}
