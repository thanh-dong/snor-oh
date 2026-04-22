import Foundation

@Observable
final class AwayDigestCollector {

    // MARK: - Config

    /// Live-toggle gate. Turning off discards any in-progress accumulation.
    var enabled: Bool = true {
        didSet {
            if !enabled { digests.removeAll(); isAccumulating = false }
        }
    }

    // MARK: - State

    private weak var sessionManager: SessionManager?
    private var digests: [String: ProjectDigest] = [:]
    private var isAccumulating: Bool = false
    private var windowEnd: Date? = nil
    private var observers: [NSObjectProtocol] = []

    // MARK: - Lifecycle

    init(sessionManager: SessionManager) {
        self.sessionManager = sessionManager
        subscribe()
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: - Public API

    /// Live digest (mutable accumulator) — primarily for tests.
    func digest(for path: String) -> ProjectDigest? {
        digests[path]
    }

    /// Immutable snapshot rollup, consumed by tooltip + bubble.
    func snapshot(for path: String) -> DigestSnapshot? {
        guard let d = digests[path], let end = windowEnd ?? d.awayWindowEnd else { return nil }
        let snap = DigestSnapshot(from: d, windowEnd: end)
        return snap.isEmpty ? nil : snap
    }

    /// Returns a single short string suitable for a BubbleManager post, or nil
    /// when there is nothing to report (zero-activity return).
    func welcomeBackSummary() -> String? {
        let nonEmpty = digests.values.compactMap { d -> DigestSnapshot? in
            guard let end = windowEnd ?? d.awayWindowEnd else { return nil }
            let s = DigestSnapshot(from: d, windowEnd: end)
            return s.isEmpty ? nil : s
        }
        guard !nonEmpty.isEmpty else { return nil }

        if nonEmpty.count == 1 {
            let s = nonEmpty[0]
            let name = (s.projectPath as NSString).lastPathComponent
            var parts: [String] = []
            if s.taskCount > 0 {
                let mins = max(1, Int(s.totalTaskSecs / 60))
                parts.append("\(s.taskCount) task\(s.taskCount == 1 ? "" : "s") · \(mins)m")
            }
            if s.filesDelta != 0 {
                parts.append("\(abs(s.filesDelta)) file\(abs(s.filesDelta) == 1 ? "" : "s") changed")
            }
            return "\(name): " + parts.joined(separator: ", ")
        }

        return "\(nonEmpty.count) projects active while you were away — tap to see"
    }

    func clearDigest(for path: String) {
        digests.removeValue(forKey: path)
    }

    func clearAll() {
        digests.removeAll()
    }

    // MARK: - Notification wiring

    private func subscribe() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .userAwayStarted, object: nil, queue: nil) { [weak self] _ in
            self?.handleAwayStarted()
        })
        observers.append(nc.addObserver(forName: .userReturned, object: nil, queue: nil) { [weak self] _ in
            self?.handleReturned()
        })
        observers.append(nc.addObserver(forName: .taskCompleted, object: nil, queue: nil) { [weak self] note in
            self?.handleTaskCompleted(note)
        })
        observers.append(nc.addObserver(forName: .projectFileDelta, object: nil, queue: nil) { [weak self] note in
            self?.handleFileDelta(note)
        })
        observers.append(nc.addObserver(forName: .statusChanged, object: nil, queue: nil) { [weak self] note in
            self?.handleStatusChanged(note)
        })
    }

    // MARK: - Handlers

    private func handleAwayStarted() {
        guard enabled else { return }
        digests.removeAll()
        isAccumulating = true
        windowEnd = nil
    }

    private func handleReturned() {
        guard enabled else { return }
        isAccumulating = false
        windowEnd = Date()
        for key in digests.keys {
            digests[key]?.awayWindowEnd = windowEnd
        }
    }

    private func handleTaskCompleted(_ note: Notification) {
        guard enabled, isAccumulating else { return }
        guard let pid = note.userInfo?["pid"] as? UInt32 else { return }
        guard let path = sessionManager?.sessions[pid]?.cwd else { return }
        let duration = note.userInfo?["duration_secs"] as? UInt64 ?? 0
        record(path: path, event: ProjectEvent(
            kind: .task, timestamp: Date(),
            durationSecs: duration, filesDelta: 0
        ))
    }

    private func handleFileDelta(_ note: Notification) {
        guard enabled, isAccumulating else { return }
        guard let path = note.userInfo?["path"] as? String else { return }
        let delta = note.userInfo?["delta"] as? Int ?? 0
        guard delta != 0 else { return }
        record(path: path, event: ProjectEvent(
            kind: .filesChanged, timestamp: Date(),
            durationSecs: 0, filesDelta: delta
        ))
    }

    private func handleStatusChanged(_ note: Notification) {
        guard enabled, isAccumulating else { return }
        let newRaw = note.userInfo?["status"] as? String
        let prevRaw = note.userInfo?["previous"] as? String
        guard newRaw == Status.disconnected.rawValue,
              prevRaw != Status.disconnected.rawValue,
              let sm = sessionManager else { return }
        for path in Set(sm.sessions.values.compactMap(\.cwd)) {
            record(path: path, event: ProjectEvent(
                kind: .sessionEnded, timestamp: Date(),
                durationSecs: 0, filesDelta: 0
            ))
        }
    }

    // MARK: - Internals

    private func record(path: String, event: ProjectEvent) {
        if digests[path] == nil {
            digests[path] = ProjectDigest(
                projectPath: path,
                awayWindowStart: Date(),
                awayWindowEnd: nil,
                events: []
            )
        }
        digests[path]?.append(event)
    }
}
