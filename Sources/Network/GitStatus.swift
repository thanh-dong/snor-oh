import Foundation

/// Polls `git status --porcelain` for each tracked project directory.
/// Updates modified file counts on SessionManager every 30 seconds.
/// Throttled: only polls unique CWD paths, skips non-git directories.
final class GitStatusPoller {
    private var timer: Timer?
    private let sessionManager: SessionManager
    private let pollInterval: TimeInterval

    /// Cache of last-known file counts to avoid unnecessary @Observable updates.
    private var lastCounts: [String: Int] = [:]

    /// Paths currently being polled — prevents concurrent Process spawns for the same dir.
    private var inFlight: Set<String> = []

    init(sessionManager: SessionManager, pollInterval: TimeInterval = 30.0) {
        self.sessionManager = sessionManager
        self.pollInterval = pollInterval
    }

    func start() {
        poll()
        let t = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let projects = sessionManager.projects
        guard !projects.isEmpty else { return }

        let paths = Set(projects.map(\.path))

        // Prune stale entries for removed projects
        lastCounts = lastCounts.filter { paths.contains($0.key) }

        for path in paths {
            guard !inFlight.contains(path) else { continue }
            inFlight.insert(path)

            gitModifiedCount(at: path) { [weak self] count in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.inFlight.remove(path)
                    guard let count else { return }
                    self.applyCount(count, forPath: path)
                }
            }
        }
    }

    private func applyCount(_ count: Int, forPath path: String) {
        if lastCounts[path] == count { return }
        let prev = lastCounts[path] ?? count  // seed to count on first observation → delta 0
        if count != prev {
            NotificationCenter.default.post(
                name: .projectFileDelta,
                object: nil,
                userInfo: ["path": path, "delta": count - prev]
            )
        }
        lastCounts[path] = count
        sessionManager.updateModifiedFiles(forPath: path, count: count)
    }

    /// Runs `git status --porcelain` in the given directory on a background queue.
    /// Returns the number of modified/untracked files, or nil if not a git repo.
    private func gitModifiedCount(at path: String, completion: @escaping (Int?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            let pipe = Pipe()

            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["status", "--porcelain"]
            process.currentDirectoryURL = URL(fileURLWithPath: path)
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
            } catch {
                completion(nil)
                return
            }

            // Read BEFORE waitUntilExit to avoid pipe buffer deadlock
            // (git output > 64KB would block the write end if we wait first)
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                completion(nil)
                return
            }

            guard let output = String(data: data, encoding: .utf8) else {
                completion(0)
                return
            }

            let count = output
                .split(separator: "\n", omittingEmptySubsequences: true)
                .count
            completion(count)
        }
    }
}
