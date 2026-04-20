import Foundation
import Darwin

// MARK: - Pidfile

/// On-disk record of a tracked session, stored at
/// `~/.snor-oh/sessions/<pid>.json`. Written by shell rc / Claude SessionStart
/// hook at registration time; deleted at clean exit. Used by snor-oh to
/// re-discover sessions after an app relaunch — the PID's actual liveness is
/// verified via `SessionLiveness.isAlive`, so stale files are self-healing.
///
/// `startedAt` comes from `ps -o lstart=` so it's comparable across shell /
/// Swift producers. It defends against macOS PID reuse: if the PID exists but
/// was started at a different time, the session is a different process.
struct SessionPidfile: Codable {
    let pid: UInt32
    let cwd: String
    let kind: String      // "shell" | "claude"
    let startedAt: String // `ps -o lstart=` string, e.g. "Mon Apr 20 14:30:12 2026"

    enum CodingKeys: String, CodingKey {
        case pid
        case cwd
        case kind
        case startedAt = "started_at"
    }
}

enum SessionPidfileStore {
    /// `~/.snor-oh/sessions`
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".snor-oh/sessions", isDirectory: true)
    }

    /// Reads every `<pid>.json` pidfile under `~/.snor-oh/sessions`. Malformed
    /// files are skipped silently — the next clean write overwrites them.
    static func scan() -> [SessionPidfile] {
        let dir = directory
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        let dec = JSONDecoder()
        return files.compactMap { url -> SessionPidfile? in
            guard url.pathExtension == "json",
                  let data = try? Data(contentsOf: url),
                  let rec = try? dec.decode(SessionPidfile.self, from: data) else {
                return nil
            }
            return rec
        }
    }

    /// Deletes the pidfile for `pid` if it exists. No-op otherwise.
    static func delete(pid: UInt32) {
        let url = directory.appendingPathComponent("\(pid).json")
        try? FileManager.default.removeItem(at: url)
    }

    /// Removes pidfiles whose PIDs no longer map to a live process with the
    /// recorded start time. Called at snor-oh launch to garbage-collect files
    /// left behind by crashed shells during snor-oh-down periods.
    static func pruneStale(using liveness: SessionLivenessChecking = SessionLiveness()) -> [SessionPidfile] {
        let all = scan()
        var alive: [SessionPidfile] = []
        for rec in all {
            if liveness.isAlive(pid: rec.pid, expectedStartedAt: rec.startedAt) {
                alive.append(rec)
            } else {
                delete(pid: rec.pid)
            }
        }
        return alive
    }
}

// MARK: - Process liveness

protocol SessionLivenessChecking {
    /// `true` iff `pid` names a live process whose start time matches
    /// `expectedStartedAt` (if provided). Start-time comparison defends
    /// against PID reuse. Passing `nil` for expected means "don't care about
    /// reuse" — used by pre-`/session-start` heartbeat-created sessions.
    func isAlive(pid: UInt32, expectedStartedAt: String?) -> Bool
}

/// Production implementation backed by `kill(pid, 0)` and `ps -o lstart=`.
/// `kill(_, 0)` sends no actual signal — it returns 0 if the process exists
/// and the caller is permitted to signal it, ESRCH otherwise. Microsecond
/// cost, no side effects. Start-time check shells out to `ps` and is only
/// invoked when `expectedStartedAt` is provided (scan path).
struct SessionLiveness: SessionLivenessChecking {
    func isAlive(pid: UInt32, expectedStartedAt: String?) -> Bool {
        guard kill(pid_t(pid), 0) == 0 else { return false }
        guard let expected = expectedStartedAt else { return true }
        guard let actual = Self.processStartedAt(pid: pid) else { return false }
        return actual == expected
    }

    /// Runs `ps -o lstart= -p <pid>` and trims the result. Returns nil if ps
    /// fails or the process is gone. Used by the scan path only; the 2s
    /// Watchdog tick sticks to `kill(0)` for cost reasons (no fork/exec).
    static func processStartedAt(pid: UInt32) -> String? {
        ProcessRunner.captureString(
            launchPath: "/bin/ps",
            arguments: ["-o", "lstart=", "-p", "\(pid)"]
        )
    }
}

// MARK: - Process scanner (fallback discovery)

/// Best-effort enumeration of currently-running interactive shells. Used to
/// populate the session list on snor-oh startup for shells that pre-date the
/// event-driven `/session-start` flow — e.g. terminals that were already open
/// before snor-oh was upgraded. Pidfile-based discovery is still the primary
/// source; this fills the gap for users who don't re-source their rc files.
struct ShellProcessInfo {
    let pid: UInt32
    let cwd: String?
    let startedAt: String?
}

protocol SessionProcessScanning {
    func scanInteractiveShells() -> [ShellProcessInfo]
}

struct SessionProcessScanner: SessionProcessScanning {
    /// Shell binaries we recognize as interactive. `ps comm=` returns the
    /// executable name without path — login shells may prefix with `-`.
    private static let shellNames: Set<String> = [
        "zsh", "-zsh", "bash", "-bash", "fish", "-fish",
    ]

    /// Process names we accept as the direct parent of a "real" terminal
    /// session. A shell whose parent isn't in this set is likely owned by an
    /// IDE / helper (VSCode integrated terminals, Code Helper, LSPs spawning
    /// sh, etc.) — those aren't user-facing terminal sessions for our
    /// purposes and would inflate the count.
    ///
    /// Entries are matched by basename. Multiplexers are included so
    /// tmux/screen panes still count; `login` covers Terminal.app and iTerm2.
    private static let terminalParentNames: Set<String> = [
        // macOS login wrapper used by Terminal.app / iTerm2 default flow
        "login",
        // Terminal emulators (direct-spawn flow)
        "Terminal", "iTerm2", "iTerm",
        "Warp", "WarpTerminal", "stable",    // Warp renames between channels
        "ghostty", "Ghostty",
        "kitty",
        "Alacritty", "alacritty",
        "wezterm", "wezterm-gui",
        "Hyper",
        // Multiplexers — shells inside tmux/screen panes count as sessions
        "tmux", "screen",
    ]

    func scanInteractiveShells() -> [ShellProcessInfo] {
        // Single ps call with ppid included so we can resolve each shell's
        // parent's comm without a second fork/exec per candidate.
        guard let result = ProcessRunner.runCapture(
            launchPath: "/bin/ps",
            arguments: ["-axo", "pid=,ppid=,tty=,comm="]
        ), result.exitCode == 0 else { return [] }
        let output = String(data: result.stdout, encoding: .utf8) ?? ""

        // Pass 1: parse everything into a table keyed by pid so we can look up
        // each candidate's parent without a second ps call.
        struct Row { let pid: UInt32; let ppid: UInt32; let tty: String; let comm: String }
        var table: [UInt32: Row] = [:]
        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let parts = line.split(whereSeparator: { $0 == " " })
                .filter { !$0.isEmpty }
            guard parts.count >= 4,
                  let pid = UInt32(parts[0]),
                  let ppid = UInt32(parts[1])
            else { continue }
            let tty = String(parts[2])
            let commRaw = parts[3...].joined(separator: " ")
            let comm = (commRaw as NSString).lastPathComponent
            table[pid] = Row(pid: pid, ppid: ppid, tty: tty, comm: comm)
        }

        let selfPid = UInt32(getpid())
        var out: [ShellProcessInfo] = []
        for row in table.values {
            guard row.pid != selfPid else { continue }
            guard row.tty != "?" && row.tty != "??" else { continue }
            guard Self.shellNames.contains(row.comm) else { continue }

            // Parent-process filter: only accept shells spawned by a known
            // terminal emulator / login / multiplexer. This is what prevents
            // inflated counts from VSCode-style embedded shells and random
            // tool-spawned shells sharing a TTY with something else.
            let parentComm = table[row.ppid]?.comm ?? ""
            guard Self.terminalParentNames.contains(parentComm) else { continue }

            let cwd = Self.cwd(for: row.pid)
            let startedAt = SessionLiveness.processStartedAt(pid: row.pid)
            out.append(ShellProcessInfo(pid: row.pid, cwd: cwd, startedAt: startedAt))
        }
        return out
    }

    /// Resolves a process's cwd via `lsof -a -d cwd -Fn -p <pid>`. `-F` emits
    /// one field per line prefixed by a letter — `n<path>` carries the cwd.
    /// ~10-50 ms per pid; called once per shell at app launch only.
    private static func cwd(for pid: UInt32) -> String? {
        guard let result = ProcessRunner.runCapture(
            launchPath: "/usr/sbin/lsof",
            arguments: ["-a", "-d", "cwd", "-Fn", "-p", "\(pid)"]
        ), result.exitCode == 0 else { return nil }
        let output = String(data: result.stdout, encoding: .utf8) ?? ""
        for line in output.split(separator: "\n") where line.hasPrefix("n") {
            let path = String(line.dropFirst())
            return path.isEmpty ? nil : path
        }
        return nil
    }
}
