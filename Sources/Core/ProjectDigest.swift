import Foundation

// MARK: - Event kinds tracked inside an away window

enum ProjectEventKind {
    case task           // busy -> idle transition completed a task
    case sessionEnded   // a session disappeared (any -> disconnected)
    case filesChanged   // git status delta (cumulative via filesDelta)
}

// MARK: - Raw event (stored per project during accumulation)

struct ProjectEvent {
    let kind: ProjectEventKind
    let timestamp: Date
    let durationSecs: UInt64  // 0 for non-task events
    let filesDelta: Int       // signed; meaningful only for .filesChanged
}

// MARK: - Per-project digest maintained by the collector

struct ProjectDigest {
    let projectPath: String
    var awayWindowStart: Date
    var awayWindowEnd: Date?  // nil while accumulating; set on snapshot
    var events: [ProjectEvent]

    static let eventCap = 20  // oldest evicted when exceeded

    var isEmpty: Bool { events.isEmpty }

    mutating func append(_ event: ProjectEvent) {
        events.append(event)
        if events.count > Self.eventCap {
            events.removeFirst(events.count - Self.eventCap)
        }
    }
}

// MARK: - Immutable snapshot consumed by tooltip + bubble

struct DigestSnapshot {
    let projectPath: String
    let awayWindowStart: Date
    let awayWindowEnd: Date
    let taskCount: Int
    let totalTaskSecs: UInt64
    let filesDelta: Int          // net across the window
    let sessionsEnded: Int
    let lastActivity: Date?

    init(from digest: ProjectDigest, windowEnd: Date) {
        self.projectPath = digest.projectPath
        self.awayWindowStart = digest.awayWindowStart
        self.awayWindowEnd = windowEnd

        var taskCount = 0
        var totalTaskSecs: UInt64 = 0
        var filesDelta = 0
        var sessionsEnded = 0
        var lastActivity: Date? = nil

        for e in digest.events {
            switch e.kind {
            case .task:
                taskCount += 1
                totalTaskSecs += e.durationSecs
            case .sessionEnded:
                sessionsEnded += 1
            case .filesChanged:
                filesDelta += e.filesDelta
            }
            if lastActivity == nil || e.timestamp > lastActivity! {
                lastActivity = e.timestamp
            }
        }

        self.taskCount = taskCount
        self.totalTaskSecs = totalTaskSecs
        self.filesDelta = filesDelta
        self.sessionsEnded = sessionsEnded
        self.lastActivity = lastActivity
    }

    var isEmpty: Bool {
        taskCount == 0 && filesDelta == 0 && sessionsEnded == 0
    }
}
