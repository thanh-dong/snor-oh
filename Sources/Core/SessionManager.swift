import Foundation
import AppKit

// MARK: - Notification Names

extension Notification.Name {
    static let statusChanged = Notification.Name("statusChanged")
    static let taskCompleted = Notification.Name("taskCompleted")
    static let mcpSay = Notification.Name("mcpSay")
    static let mcpReact = Notification.Name("mcpReact")
    static let peersChanged = Notification.Name("peersChanged")
    static let visitorArrived = Notification.Name("visitorArrived")
    static let visitorLeft = Notification.Name("visitorLeft")
    static let discoveryHint = Notification.Name("discoveryHint")

    /// Posted by `BucketManager` on every item add/remove/pin/clear.
    /// `userInfo`:
    ///   - `"source": String` — see `BucketChangeSource`
    ///   - `"change": String` — see `BucketChangeKind`
    ///   - `"itemID": UUID?` — nil on bulk changes like `.cleared`
    /// Contract source: docs/prd/bucket/REVIEW.md §6.
    static let bucketChanged = Notification.Name("bucketChanged")

    /// Epic 02 — posted once per session per threshold (20/50/100) when the
    /// total active-bucket item count crosses. `userInfo`:
    ///   - `"threshold": Int`
    ///   - `"count": Int`
    static let bucketHeavy = Notification.Name("bucketHeavy")

    /// A9 — posted by UserIdleTracker when user-idle exceeds the configured
    /// threshold (default 10 min). `userInfo` is empty; the collector records
    /// its own `awayWindowStart`.
    static let userAwayStarted = Notification.Name("userAwayStarted")

    /// A9 — posted by UserIdleTracker when any real user input returns after
    /// a prior `.userAwayStarted`. `userInfo`:
    ///   - `"away_duration_secs": UInt64`
    static let userReturned = Notification.Name("userReturned")

    /// A9 — posted by GitStatus when a project's modifiedFiles count changes.
    /// `userInfo`:
    ///   - `"path": String`
    ///   - `"delta": Int`  (signed; can be negative when files revert)
    static let projectFileDelta = Notification.Name("projectFileDelta")
}

// MARK: - SessionManager

@Observable
final class SessionManager {

    // MARK: Session Tracking

    // Internal access for testing; external code should use handleStatus/handleHeartbeat/removeSession
    var sessions: [UInt32: Session] = [:]
    private(set) var currentUI: Status = .initializing
    private(set) var idleSince: Date? = nil
    private(set) var sleeping = false

    // MARK: Social

    private(set) var peers: [String: PeerInfo] = [:]
    private(set) var visitors: [VisitingDog] = []
    private(set) var visiting: String? = nil

    // MARK: Identity

    var pet: String = "sprite"
    var nickname: String = "Buddy"
    var httpPort: Int = 1425

    // MARK: Usage Analytics

    var usage = UsageToday()
    let startedAt = nowSecs()

    // MARK: Multi-Session Projects

    private(set) var projects: [ProjectStatus] = []

    // MARK: Constants

    /// Legacy fallback timeout — used only for sessions that were ever tracked
    /// without a pidfile (e.g. a pre-upgrade shell still running its old
    /// heartbeat loop). New sessions are pruned by PID liveness, not age.
    static let heartbeatTimeoutSecs: UInt64 = 600
    static let serviceDisplaySecs: UInt64 = 2
    static let idleToSleepSecs: UInt64 = 120

    // MARK: - Liveness

    /// Injectable for tests. Production uses POSIX `kill(0)` + `ps -o lstart=`.
    var livenessChecker: SessionLivenessChecking = SessionLiveness()

    /// Injectable for tests. Production scans running shells via `ps` + `lsof`.
    /// Used only at `loadExistingSessions()` time as a fallback for terminals
    /// that pre-date the event-driven registration path (no pidfile on disk).
    var processScanner: SessionProcessScanning = SessionProcessScanner()

    // MARK: - Status Handling

    func handleStatus(pid: UInt32, state: String, type: String?, cwd: String?) {
        let now = nowSecs()
        resetDailyIfNeeded()

        var session = sessions[pid] ?? Session(lastSeen: now)
        session.lastSeen = now
        if let cwd { session.cwd = cwd }

        if state == "busy" {
            let busyType = type ?? "task"
            session.busyType = busyType
            if busyType == "service" {
                session.uiState = .service
                session.serviceSince = now
                session.busySince = 0  // Clear busySince to prevent spurious task completion count
            } else {
                session.uiState = .busy
                session.busySince = now
            }
        } else if state == "idle" {
            // Calculate task duration if transitioning from busy
            if session.busySince > 0 {
                let duration = now - session.busySince
                usage.tasksCompleted += 1
                usage.totalBusySecs += duration
                usage.lastTaskDurationSecs = duration
                if duration > usage.longestTaskSecs {
                    usage.longestTaskSecs = duration
                }
                NotificationCenter.default.post(
                    name: .taskCompleted,
                    object: nil,
                    userInfo: ["duration_secs": duration, "pid": pid]
                )
            }
            session.busyType = ""
            session.uiState = .idle
            session.serviceSince = 0
            session.busySince = 0
        }

        sessions[pid] = session
        recomputeProjects()
        emitIfChanged()
    }

    func handleHeartbeat(pid: UInt32, cwd: String?) {
        let now = nowSecs()
        var session = sessions[pid] ?? Session(uiState: .idle, lastSeen: now)

        // PID-liveness is the authoritative lifecycle signal, so heartbeats
        // refresh `lastSeen` unconditionally — no more `!= .busy` gate that
        // used to strand sessions stuck in busy after a missed idle event.
        session.lastSeen = now
        if let cwd { session.cwd = cwd }

        sessions[pid] = session
        recomputeProjects()
        emitIfChanged()
    }

    /// Registers a new session from `/session-start`. Called by shell rc and
    /// Claude's `SessionStart` hook — replaces the implicit "heartbeat created
    /// the session" shortcut. Carries `startedAt` so PID reuse is detectable.
    func handleSessionStart(pid: UInt32, cwd: String?, kind: String?, startedAt: String?) {
        let now = nowSecs()
        var session = sessions[pid] ?? Session(uiState: .idle, lastSeen: now)
        session.lastSeen = now
        if let cwd { session.cwd = cwd }
        session.kind = kind
        session.startedAt = startedAt
        if session.uiState == .disconnected {
            session.uiState = .idle
        }
        sessions[pid] = session
        recomputeProjects()
        emitIfChanged()
    }

    /// Removes a session at the producer's explicit request — shell EXIT trap,
    /// Claude `SessionEnd` hook. Watchdog's PID-liveness sweep is the safety
    /// net for anything that skipped this path (SIGKILL, force-quit).
    func handleSessionEnd(pid: UInt32) {
        guard sessions[pid] != nil else { return }
        sessions.removeValue(forKey: pid)
        recomputeProjects()
        emitIfChanged()
    }

    /// Seeds `sessions` at app launch so the UI shows already-open
    /// terminals/Claude sessions without waiting for the first event.
    ///
    /// Two-pass discovery:
    ///   1. Pidfile scan — authoritative when present. Carries kind +
    ///      started_at metadata so PID reuse is detectable.
    ///   2. Process scan (shells only) — fallback for terminals that
    ///      pre-date the event-driven `/session-start` flow (no pidfile).
    ///      Deduped against pass 1 by PID.
    ///
    /// Called from `AppDelegate.applicationDidFinishLaunching` AFTER the HTTP
    /// server binds but BEFORE the watchdog starts — otherwise the first tick
    /// could race the scan.
    func loadExistingSessions() {
        let alive = SessionPidfileStore.pruneStale(using: livenessChecker)
        let now = nowSecs()
        for rec in alive where sessions[rec.pid] == nil {
            sessions[rec.pid] = Session(
                busyType: "",
                uiState: .idle,
                lastSeen: now,
                cwd: rec.cwd,
                startedAt: rec.startedAt,
                kind: rec.kind
            )
        }

        // Fallback scan: pick up shells that never registered via /session-start
        // (pre-upgrade terminals). Skip if already tracked via pidfile.
        for shell in processScanner.scanInteractiveShells()
        where sessions[shell.pid] == nil {
            sessions[shell.pid] = Session(
                busyType: "",
                uiState: .idle,
                lastSeen: now,
                cwd: shell.cwd,
                startedAt: shell.startedAt,
                kind: "shell"
            )
        }

        recomputeProjects()
        emitIfChanged()
    }

    // MARK: - UI State Resolution

    func resolveUIState() -> Status {
        if sessions.isEmpty {
            return .disconnected
        }
        var winner: Status = .disconnected
        for (_, session) in sessions {
            if session.uiState.priority > winner.priority {
                winner = session.uiState
            }
        }
        return winner
    }

    private var lastProjectCount: Int = 0

    func emitIfChanged() {
        let newUI = resolveUIState()

        // If sleeping, only busy/service wakes up
        if sleeping && newUI != .busy && newUI != .service {
            return
        }
        if sleeping && (newUI == .busy || newUI == .service) {
            sleeping = false
        }

        let oldUI = currentUI
        var changed = false
        if newUI != currentUI {
            currentUI = newUI
            changed = true

            if newUI == .idle {
                idleSince = Date()
            } else {
                idleSince = nil
            }
        }

        // Detect project-count changes (new cwd appeared/gone). Session-count
        // changes that don't move project count (e.g. 2nd shell in an existing
        // folder) are intentionally NOT re-rendered — projects are the UI unit.
        let projectCount = projects.count
        if projectCount != lastProjectCount {
            lastProjectCount = projectCount
            changed = true
        }

        if changed {
            NotificationCenter.default.post(
                name: .statusChanged,
                object: nil,
                userInfo: ["status": newUI.rawValue, "previous": oldUI.rawValue]
            )
        }
    }

    // MARK: - Watchdog Support

    /// Called by Watchdog every 2 seconds.
    func tick() {
        let now = nowSecs()

        // 1. Service → Idle transition
        var serviceTransitioned = false
        for (pid, session) in sessions where session.uiState == .service && session.serviceSince > 0 {
            if session.serviceSince <= now && now - session.serviceSince >= Self.serviceDisplaySecs {
                sessions[pid]?.uiState = .idle
                sessions[pid]?.serviceSince = 0
                serviceTransitioned = true
            }
        }

        // 2. Dead-PID cleanup. `kill(pid, 0)` is the authoritative liveness
        //    signal — instant and side-effect free. Start-time comparison is
        //    skipped here (too expensive for a 2s tick) and handled at scan
        //    time. Legacy sessions without pidfiles are additionally aged out
        //    by `heartbeatTimeoutSecs` so a pre-upgrade shell that somehow
        //    stopped heartbeating doesn't linger forever.
        var stale: [UInt32] = []
        for (pid, session) in sessions {
            if !livenessChecker.isAlive(pid: pid, expectedStartedAt: nil) {
                stale.append(pid)
                continue
            }
            if session.startedAt == nil,
               session.lastSeen <= now,
               now - session.lastSeen >= Self.heartbeatTimeoutSecs {
                stale.append(pid)
            }
        }
        for pid in stale {
            sessions.removeValue(forKey: pid)
            SessionPidfileStore.delete(pid: pid)
        }

        // 3. Visitor expiration (guard against clock skew)
        let expired = visitors.filter { $0.arrivedAt <= now && now - $0.arrivedAt >= $0.durationSecs }
        for visitor in expired {
            NotificationCenter.default.post(
                name: .visitorLeft,
                object: nil,
                userInfo: ["instance_name": visitor.instanceName, "nickname": visitor.nickname]
            )
        }
        visitors.removeAll { v in expired.contains { $0.instanceName == v.instanceName } }

        // 4. Recompute projects after any session changes
        if !stale.isEmpty || serviceTransitioned {
            recomputeProjects()
        }

        // 5. Idle → Sleep transition
        if currentUI == .idle, let idleSince, Date().timeIntervalSince(idleSince) >= Double(Self.idleToSleepSecs) {
            sleeping = true
            self.idleSince = nil
            currentUI = .disconnected
            NotificationCenter.default.post(
                name: .statusChanged,
                object: nil,
                userInfo: ["status": Status.disconnected.rawValue, "previous": Status.idle.rawValue]
            )
            return
        }

        emitIfChanged()
    }

    // MARK: - Visitor Management

    static let maxVisitors = 5

    func addVisitor(_ visitor: VisitingDog) {
        // Remove existing visitor with same instance name
        visitors.removeAll { $0.instanceName == visitor.instanceName }
        // Cap duration at 60 seconds
        let capped = VisitingDog(
            instanceName: visitor.instanceName,
            pet: visitor.pet,
            nickname: visitor.nickname,
            arrivedAt: visitor.arrivedAt,
            durationSecs: min(visitor.durationSecs, 60)
        )
        // Cap total visitors
        if visitors.count >= Self.maxVisitors {
            visitors.removeFirst()
        }
        visitors.append(capped)
        NotificationCenter.default.post(
            name: .visitorArrived,
            object: nil,
            userInfo: ["visitor": visitor]
        )
    }

    func removeVisitor(instanceName: String?, nickname: String?) {
        if let name = instanceName {
            visitors.removeAll { $0.instanceName == name }
        } else if let nick = nickname {
            visitors.removeAll { $0.nickname == nick }
        }
        NotificationCenter.default.post(
            name: .visitorLeft,
            object: nil,
            userInfo: [
                "instance_name": instanceName ?? "",
                "nickname": nickname ?? "",
            ]
        )
    }

    // MARK: - Peer Management

    func addPeer(_ peer: PeerInfo) {
        peers[peer.instanceName] = peer
        NotificationCenter.default.post(name: .peersChanged, object: nil)
    }

    func removePeer(instanceName: String) {
        peers.removeValue(forKey: instanceName)
        NotificationCenter.default.post(name: .peersChanged, object: nil)
    }

    func clearAllPeers() {
        peers.removeAll()
        visiting = nil
        NotificationCenter.default.post(name: .peersChanged, object: nil)
    }

    // MARK: - Visiting

    func setVisiting(_ peerInstanceName: String) {
        visiting = peerInstanceName
    }

    func clearVisiting() {
        visiting = nil
    }

    // MARK: - Session Removal

    func removeSession(pid: UInt32) {
        sessions.removeValue(forKey: pid)
        recomputeProjects()
        emitIfChanged()
    }

    // MARK: - MCP Handlers

    func handleMCPSay(message: String, durationMs: UInt64) {
        NotificationCenter.default.post(
            name: .mcpSay,
            object: nil,
            userInfo: ["message": message, "duration_ms": durationMs]
        )
    }

    func handleMCPReact(reaction: String, durationMs: UInt64) {
        let mappedStatus: String
        switch reaction {
        case "celebrate", "excited": mappedStatus = Status.service.rawValue
        case "nervous": mappedStatus = Status.busy.rawValue
        case "confused": mappedStatus = Status.searching.rawValue
        case "sleep": mappedStatus = Status.disconnected.rawValue
        default: mappedStatus = Status.idle.rawValue
        }
        NotificationCenter.default.post(
            name: .mcpReact,
            object: nil,
            userInfo: ["status": mappedStatus, "duration_ms": durationMs]
        )
    }

    // MARK: - Pet Status (MCP Response)

    func petStatusJSON() -> PetStatusResponse {
        let now = nowSecs()
        let longestBusy = sessions.values
            .filter { $0.uiState == .busy && $0.busySince > 0 }
            .map { now - $0.busySince }
            .max() ?? 0

        return PetStatusResponse(
            petType: pet,
            nickname: nickname,
            currentStatus: currentUI.rawValue,
            sleeping: sleeping,
            sessionsActive: sessions.count,
            peersNearby: peers.count,
            visitors: visitors.map { VisitorInfo(nickname: $0.nickname, pet: $0.pet) },
            isVisiting: visiting != nil,
            uptimeSecs: now - startedAt,
            currentBusySecs: longestBusy,
            usageToday: UsageTodayResponse(
                tasksCompleted: usage.tasksCompleted,
                totalBusyMins: usage.totalBusySecs / 60,
                longestTaskMins: usage.longestTaskSecs / 60,
                lastTaskDurationSecs: usage.lastTaskDurationSecs
            ),
            projects: projects.map {
                ProjectInfo(
                    name: $0.name,
                    status: $0.status.rawValue,
                    modifiedFiles: $0.modifiedFiles,
                    sessions: $0.sessions.count
                )
            }
        )
    }

    // MARK: - Project File Count Update

    func updateModifiedFiles(forPath path: String, count: Int) {
        if let idx = projects.firstIndex(where: { $0.path == path }) {
            projects[idx].modifiedFiles = count
        }
    }

    // MARK: - Project Aggregation

    private func recomputeProjects() {
        // Snapshot existing file counts so we can carry them forward
        let existingCounts = Dictionary(uniqueKeysWithValues: projects.map { ($0.path, $0.modifiedFiles) })

        var grouped: [String: [UInt32: Session]] = [:]
        for (pid, session) in sessions {
            guard let path = session.cwd else { continue } // Skip sessions with no CWD
            grouped[path, default: [:]][pid] = session
        }

        projects = grouped.map { (path, pidSessions) in
            let name = (path as NSString).lastPathComponent
            let pids = Array(pidSessions.keys)

            // Aggregate status: highest priority wins
            let status = pidSessions.values
                .map(\.uiState)
                .max(by: { $0.priority < $1.priority }) ?? .idle

            // activeSince: earliest relevant timestamp for current aggregate status
            let activeSince: Date
            if status == .busy {
                let earliest = pidSessions.values
                    .filter { $0.uiState == .busy && $0.busySince > 0 }
                    .map(\.busySince)
                    .min() ?? nowSecs()
                activeSince = Date(timeIntervalSince1970: TimeInterval(earliest))
            } else {
                activeSince = Date()
            }

            return ProjectStatus(
                path: path,
                name: name,
                status: status,
                sessions: pids,
                activeSince: activeSince,
                modifiedFiles: existingCounts[path] ?? 0
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Daily Reset

    private func resetDailyIfNeeded() {
        let today = currentDay()
        if usage.usageDay != today {
            usage = UsageToday(usageDay: today)
        }
    }
}
